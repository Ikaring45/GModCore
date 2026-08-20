using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

/// <summary>
/// Owns one run-scoped directory below an existing addons directory. Ownership
/// is anchored by a retained directory handle and file identity, never by a
/// later path-name search.
/// </summary>
public sealed class SourceOracleOwnedMount : IDisposable
{
    public const string MarkerFileName = ".source_oracle_owned_mount_v1";

    private const uint DeleteAccess = 0x00010000;
    private const uint FileListDirectory = 0x00000001;
    private const uint FileReadAttributes = 0x00000080;
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint CreateNew = 1;
    private const uint OpenExisting = 3;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeDevice = 0x00000040;
    private const uint FileAttributeNormal = 0x00000080;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagSequentialScan = 0x08000000;
    private const int FileDispositionInfo = 4;
    private const int FileIdInfo = 18;
    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;
    private const int ErrorFileExists = 80;
    private const int ErrorAlreadyExists = 183;

    private readonly object sync = new object();
    private readonly string rootPath;
    private readonly string addonsRootPath;
    private readonly Dictionary<string, ExpectedEntry> expectedEntries;
    private readonly Dictionary<string, SafeKernelHandle> ownedDirectoryHandles;
    private SafeKernelHandle targetHandle;
    private SafeKernelHandle targetWriteGuard;
    private FileIdentity targetIdentity;
    private bool copyAttempted;
    private bool cleaned;
    private bool disposed;

    private SourceOracleOwnedMount(
        string rootPath,
        string addonsRootPath,
        string targetPath,
        string runId,
        string mountToken,
        SafeKernelHandle targetHandle,
        SafeKernelHandle targetWriteGuard,
        FileIdentity targetIdentity,
        FileIdentity markerIdentity)
    {
        this.rootPath = rootPath;
        this.addonsRootPath = addonsRootPath;
        TargetPath = targetPath;
        RunId = runId;
        MountToken = mountToken;
        this.targetHandle = targetHandle;
        this.targetWriteGuard = targetWriteGuard;
        this.targetIdentity = targetIdentity;
        expectedEntries = new Dictionary<string, ExpectedEntry>(
            StringComparer.OrdinalIgnoreCase);
        ownedDirectoryHandles = new Dictionary<string, SafeKernelHandle>(
            StringComparer.OrdinalIgnoreCase);
        expectedEntries.Add(
            MarkerFileName,
            new ExpectedEntry(MarkerFileName, markerIdentity, false));
    }

    public string TargetPath { get; private set; }

    public string RunId { get; private set; }

    public string MountToken { get; private set; }

    public ulong FileIdLow
    {
        get { return targetIdentity.FileIdLow; }
    }

    public ulong FileIdHigh
    {
        get { return targetIdentity.FileIdHigh; }
    }

    public ulong VolumeSerialNumber
    {
        get { return targetIdentity.VolumeSerialNumber; }
    }

    public string ExpectedMarkerContents
    {
        get { return BuildMarkerContents(RunId, MountToken); }
    }

    /// <summary>
    /// Uses exclusive CreateDirectoryW name creation for a unique runID-bearing
    /// direct addons child, then immediately retains a non-share-delete handle.
    /// </summary>
    public static SourceOracleOwnedMount Create(
        string rootPath,
        string addonsRootPath,
        string runId)
    {
        ValidateRunId(runId);
        string root = NormalizeExistingDirectory(rootPath, "rootPath");
        string addons = NormalizeExistingDirectory(addonsRootPath, "addonsRootPath");

        if (!IsStrictlyUnder(addons, root))
        {
            throw new ArgumentException(
                "The addons root must be a strict descendant of rootPath",
                "addonsRootPath");
        }

        AssertPathContainsNoReparsePoint(root, true);
        AssertPathContainsNoReparsePoint(addons, true);

        List<SafeKernelHandle> guards = null;
        SafeKernelHandle ownedTarget = null;
        SafeKernelHandle rootWriteGuard = null;
        string target = null;
        bool directoryWasCreated = false;

        try
        {
            guards = OpenDirectoryGuards(root, addons);

            string mountToken = null;
            for (int attempt = 0; attempt < 8; attempt++)
            {
                mountToken = Guid.NewGuid().ToString("N");
                string leaf = "garryspad_source_oracle_" + runId + "_" + mountToken;
                target = Path.Combine(addons, leaf);
                if (!String.Equals(
                    Path.GetDirectoryName(target),
                    addons,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "The generated mount is not a direct addons child");
                }

                if (NativeMethods.CreateDirectory(ToExtendedPath(target), IntPtr.Zero))
                {
                    directoryWasCreated = true;
                    break;
                }

                int createError = Marshal.GetLastWin32Error();
                if (createError != ErrorAlreadyExists && createError != ErrorFileExists)
                {
                    throw new Win32Exception(
                        createError,
                        "CreateDirectoryW failed for the owned mount");
                }
            }

            if (!directoryWasCreated)
            {
                throw new IOException(
                    "Could not atomically allocate a unique owned mount name");
            }

            ownedTarget = OpenHandle(
                target,
                DeleteAccess | FileReadAttributes,
                FileShareRead | FileShareWrite,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                "owned target directory");
            FileIdentity ownedIdentity = ReadIdentity(ownedTarget, "owned target directory");
            RequirePlainDirectory(ownedIdentity, "owned target directory");

            // Retain a second, read/list-only root handle that denies share-write.
            // SHARE_DELETE is required only because the ownership handle already
            // has DELETE access. This closes the empty-root reparse window before
            // the marker is created and remains held for the mount lifetime.
            rootWriteGuard = OpenHandle(
                target,
                FileListDirectory | FileReadAttributes,
                FileShareRead | FileShareDelete,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                "owned target no-write guard");
            FileIdentity rootGuardIdentity = ReadIdentity(
                rootWriteGuard,
                "owned target no-write guard");
            RequirePlainDirectory(rootGuardIdentity, "owned target no-write guard");
            RequireSameIdentity(
                ownedIdentity,
                rootGuardIdentity,
                "Owned target changed before its no-write guard was acquired");

            FileIdentity markerIdentity = CreateMarkerFile(
                Path.Combine(target, MarkerFileName),
                BuildMarkerContents(runId, mountToken));

            SourceOracleOwnedMount mount = new SourceOracleOwnedMount(
                root,
                addons,
                target,
                runId,
                mountToken,
                ownedTarget,
                rootWriteGuard,
                ownedIdentity,
                markerIdentity);
            ownedTarget = null;
            rootWriteGuard = null;
            return mount;
        }
        catch (Exception error)
        {
            // If construction cannot prove a same-handle cleanup, the unique
            // directory is deliberately left in place for manual inspection.
            if (target != null)
            {
                error.Data["SourceOracleOwnedTargetPath"] = target;
            }
            if (rootWriteGuard != null)
            {
                rootWriteGuard.Dispose();
            }
            if (ownedTarget != null)
            {
                ownedTarget.Dispose();
            }
            throw;
        }
        finally
        {
            DisposeHandles(guards);
        }
    }

    /// <summary>
    /// Creates one generated UTF-8 file inside an already-owned destination
    /// directory and adds its exact 128-bit identity to the cleanup manifest.
    /// Parent directories must already have been created by CopyTree.
    /// </summary>
    public void WriteGeneratedFile(string relativePath, string contents)
    {
        lock (sync)
        {
            ThrowIfUnavailable();
            if (contents == null)
            {
                throw new ArgumentNullException("contents");
            }

            string normalizedRelative = ValidateGeneratedRelativePath(relativePath);
            if (expectedEntries.ContainsKey(normalizedRelative))
            {
                throw new InvalidOperationException(
                    "Generated path collides with the owned manifest: " +
                    normalizedRelative);
            }

            string parentRelative = Path.GetDirectoryName(normalizedRelative);
            string parentPath;
            ExpectedEntry expectedParent = null;
            if (String.IsNullOrEmpty(parentRelative))
            {
                parentPath = TargetPath;
            }
            else
            {
                if (!expectedEntries.TryGetValue(parentRelative, out expectedParent) ||
                    !expectedParent.IsDirectory)
                {
                    throw new InvalidOperationException(
                        "Generated-file parent is not an owned directory: " +
                        parentRelative);
                }
                parentPath = Path.Combine(TargetPath, parentRelative);
            }

            ValidateTargetIdentityByPath();
            ValidateCurrentTargetManifest();

            SafeKernelHandle parentGuard;
            SafeKernelHandle generated = null;
            try
            {
                if (expectedParent == null)
                {
                    // Root guard is READ|DELETE sharing so it is compatible with
                    // the retained root DELETE handle while denying writers.
                    parentGuard = targetWriteGuard;
                }
                else if (!ownedDirectoryHandles.TryGetValue(
                    parentRelative,
                    out parentGuard))
                {
                    throw new InvalidOperationException(
                        "Generated-file parent has no retained no-write guard: " +
                        parentRelative);
                }
                FileIdentity parentIdentity = ReadIdentity(
                    parentGuard,
                    "generated-file parent guard");
                RequirePlainDirectory(parentIdentity, "generated-file parent guard");
                if (expectedParent == null)
                {
                    RequireSameIdentity(
                        targetIdentity,
                        parentIdentity,
                        "Generated-file root parent identity mismatch");
                }
                else
                {
                    RequireSameIdentity(
                        expectedParent.Identity,
                        parentIdentity,
                        "Generated-file parent identity mismatch");
                }

                string fullPath = Path.Combine(TargetPath, normalizedRelative);
                generated = CreateNewFileHandle(
                    fullPath,
                    GenericWrite | DeleteAccess | FileReadAttributes,
                    "generated file " + normalizedRelative);
                FileIdentity identity = ReadIdentity(
                    generated,
                    "generated file " + normalizedRelative);
                RequirePlainFile(identity, "generated file " + normalizedRelative);
                expectedEntries.Add(
                    normalizedRelative,
                    new ExpectedEntry(normalizedRelative, identity, false));

                byte[] bytes = new UTF8Encoding(false, true).GetBytes(contents);
                WriteAll(generated, bytes, "generated file " + normalizedRelative);
                if (!NativeMethods.FlushFileBuffers(generated))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "FlushFileBuffers failed for generated file " +
                        normalizedRelative);
                }
            }
            finally
            {
                if (generated != null)
                {
                    generated.Dispose();
                }
            }
        }
    }

    /// <summary>
    /// Copies one plain directory tree into this mount. Source directories,
    /// files, and every component of the source path are opened without
    /// following a final reparse point. Any reparse point fails the whole call.
    /// A failed copy cannot be retried on the same mount.
    /// </summary>
    public void CopyTree(string sourcePath)
    {
        lock (sync)
        {
            ThrowIfUnavailable();
            if (copyAttempted)
            {
                throw new InvalidOperationException(
                    "CopyTree has already been attempted for this mount");
            }
            copyAttempted = true;

            string source = NormalizeExistingDirectory(sourcePath, "sourcePath");
            AssertPathContainsNoReparsePoint(source, true);
            if (PathsOverlap(source, TargetPath))
            {
                throw new InvalidOperationException(
                    "The source tree and owned target must not overlap");
            }

            ValidateTargetIdentityByPath();
            ValidateCurrentTargetManifest();

            SourceNode sourceTree = null;
            List<SafeKernelHandle> sourcePathGuards = null;
            try
            {
                sourcePathGuards = OpenDirectoryGuards(
                    Path.GetPathRoot(source),
                    source);
                sourceTree = SnapshotSourceTree(source);
                ValidateStableSourceTree(sourceTree);
                for (int index = 0; index < sourceTree.Children.Count; index++)
                {
                    CopySourceNode(sourceTree.Children[index], TargetPath);
                }
            }
            finally
            {
                if (sourceTree != null)
                {
                    sourceTree.Dispose();
                }
                DisposeHandles(sourcePathGuards);
            }
        }
    }

    /// <summary>
    /// Deletes only the exact manifest created through this instance. Identity,
    /// marker, reparse, and unknown-entry checks all occur before the first
    /// disposition request. A refusal leaves the mount for manual inspection.
    /// </summary>
    public void Cleanup()
    {
        lock (sync)
        {
            ThrowIfUnavailable();
            ValidateTargetIdentityByPath();

            List<CleanupNode> children = null;
            try
            {
                FileIdentity rootAuditIdentity = ReadIdentity(
                    targetWriteGuard,
                    "target root cleanup audit");
                RequirePlainDirectory(rootAuditIdentity, "target root cleanup audit");
                RequireSameIdentity(
                    targetIdentity,
                    rootAuditIdentity,
                    "Target root changed before cleanup audit");

                HashSet<string> seen = new HashSet<string>(
                    StringComparer.OrdinalIgnoreCase);
                children = SnapshotTargetChildren(TargetPath, String.Empty, seen);
                if (seen.Count != expectedEntries.Count)
                {
                    throw new InvalidOperationException(
                        "The target manifest has missing or unknown entries");
                }
                foreach (string expectedPath in expectedEntries.Keys)
                {
                    if (!seen.Contains(expectedPath))
                    {
                        throw new InvalidOperationException(
                            "The target manifest is missing " + expectedPath);
                    }
                }

                ValidateCleanupEntrySets(TargetPath, children);
                for (int index = 0; index < children.Count; index++)
                {
                    DeleteCleanupNode(children[index]);
                }
                children.Clear();

                if (EnumerateNames(TargetPath).Count != 0)
                {
                    throw new InvalidOperationException(
                        "The target gained an entry during cleanup");
                }

                FileIdentity currentTarget = ReadIdentity(
                    targetHandle,
                    "retained target directory");
                RequireSameIdentity(
                    targetIdentity,
                    currentTarget,
                    "retained target directory identity changed");
                RequirePlainDirectory(currentTarget, "retained target directory");

                SetDeleteDisposition(targetHandle, "retained target directory");
                targetHandle.Dispose();
                targetHandle = null;
                targetWriteGuard.Dispose();
                targetWriteGuard = null;
                cleaned = true;

                // FileDispositionInfo is handle based, but the directory name
                // can remain visible briefly while a read handle that shared
                // deletion is closing (for example, a filesystem scanner).
                // Do not report cleanup success until the owned path is gone.
                DateTime disappearanceDeadline = DateTime.UtcNow.AddSeconds(5);
                while (Directory.Exists(TargetPath) &&
                       DateTime.UtcNow < disappearanceDeadline)
                {
                    Thread.Sleep(10);
                }
                if (Directory.Exists(TargetPath))
                {
                    throw new IOException(
                        "The owned mount is delete-pending but its path did not " +
                        "disappear within five seconds: " + TargetPath);
                }
            }
            finally
            {
                DisposeCleanupNodes(children);
            }
        }
    }

    /// <summary>
    /// Dispose never attempts a path-based cleanup. If Cleanup was refused or
    /// omitted it closes the ownership handle and deliberately leaves the mount.
    /// </summary>
    public void Dispose()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            foreach (SafeKernelHandle directoryHandle in ownedDirectoryHandles.Values)
            {
                directoryHandle.Dispose();
            }
            ownedDirectoryHandles.Clear();
            if (targetWriteGuard != null)
            {
                targetWriteGuard.Dispose();
                targetWriteGuard = null;
            }
            if (targetHandle != null)
            {
                targetHandle.Dispose();
                targetHandle = null;
            }
        }
        GC.SuppressFinalize(this);
    }

    private void ValidateTargetIdentityByPath()
    {
        AssertPathContainsNoReparsePoint(rootPath, true);
        AssertPathContainsNoReparsePoint(addonsRootPath, true);
        AssertPathContainsNoReparsePoint(TargetPath, true);

        if (!String.Equals(
            Path.GetDirectoryName(TargetPath),
            addonsRootPath,
            StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "The target is no longer a direct addons child");
        }

        FileIdentity retained = ReadIdentity(targetHandle, "retained target directory");
        RequireSameIdentity(
            targetIdentity,
            retained,
            "The retained target handle identity changed");
        RequirePlainDirectory(retained, "retained target directory");

        SafeKernelHandle pathHandle = null;
        try
        {
            // SHARE_DELETE is included only on this read-only comparison handle
            // so it is compatible with the retained handle's DELETE access. The
            // retained handle itself still denies delete sharing to all writers.
            pathHandle = OpenHandle(
                TargetPath,
                FileReadAttributes,
                FileShareRead | FileShareWrite | FileShareDelete,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                "target identity comparison");
            FileIdentity byPath = ReadIdentity(pathHandle, "target identity comparison");
            RequirePlainDirectory(byPath, "target identity comparison");
            RequireSameIdentity(
                targetIdentity,
                byPath,
                "The target path no longer names the retained directory");
        }
        finally
        {
            if (pathHandle != null)
            {
                pathHandle.Dispose();
            }
        }
    }

    private void ValidateCurrentTargetManifest()
    {
        List<CleanupNode> nodes = null;
        try
        {
            HashSet<string> seen = new HashSet<string>(
                StringComparer.OrdinalIgnoreCase);
            nodes = SnapshotTargetChildren(TargetPath, String.Empty, seen);
            if (seen.Count != expectedEntries.Count)
            {
                throw new InvalidOperationException(
                    "The target contains an unknown or missing entry");
            }
            foreach (string expectedPath in expectedEntries.Keys)
            {
                if (!seen.Contains(expectedPath))
                {
                    throw new InvalidOperationException(
                        "The target is missing " + expectedPath);
                }
            }
        }
        finally
        {
            DisposeCleanupNodes(nodes);
        }
    }

    private List<CleanupNode> SnapshotTargetChildren(
        string directoryPath,
        string relativeDirectory,
        HashSet<string> seen)
    {
        List<CleanupNode> result = new List<CleanupNode>();
        List<string> names = EnumerateNames(directoryPath);
        try
        {
            for (int index = 0; index < names.Count; index++)
            {
                string name = names[index];
                string relativePath = CombineRelative(relativeDirectory, name);
                ExpectedEntry expected;
                if (!expectedEntries.TryGetValue(relativePath, out expected))
                {
                    // Do not open or descend through an unknown name.
                    throw new InvalidOperationException(
                        "Unknown target entry refused: " + relativePath);
                }
                if (!seen.Add(relativePath))
                {
                    throw new InvalidOperationException(
                        "Duplicate target entry refused: " + relativePath);
                }

                string fullPath = Path.Combine(directoryPath, name);
                uint desiredAccess = DeleteAccess | FileReadAttributes;
                if (String.Equals(
                    relativePath,
                    MarkerFileName,
                    StringComparison.OrdinalIgnoreCase))
                {
                    desiredAccess |= GenericRead;
                }

                SafeKernelHandle handle;
                bool ownsHandle;
                if (expected.IsDirectory)
                {
                    if (!ownedDirectoryHandles.TryGetValue(relativePath, out handle))
                    {
                        throw new InvalidOperationException(
                            "Owned directory has no retained no-write handle: " +
                            relativePath);
                    }
                    ownsHandle = false;
                }
                else
                {
                    handle = OpenHandle(
                        fullPath,
                        desiredAccess,
                        FileShareRead,
                        FileFlagBackupSemantics |
                            FileFlagOpenReparsePoint |
                            FileFlagSequentialScan,
                        "target child " + relativePath);
                    ownsHandle = true;
                }
                CleanupNode node = null;
                try
                {
                    FileIdentity identity = ReadIdentity(
                        handle,
                        "target child " + relativePath);
                    RequirePlainEntry(identity, "target child " + relativePath);
                    RequireSameIdentity(
                        expected.Identity,
                        identity,
                        "Target entry identity mismatch: " + relativePath);
                    if (identity.IsDirectory != expected.IsDirectory)
                    {
                        throw new InvalidOperationException(
                            "Target entry type mismatch: " + relativePath);
                    }
                    if (!identity.IsDirectory && identity.NumberOfLinks != 1)
                    {
                        throw new InvalidOperationException(
                            "Hard-linked target entry refused: " + relativePath);
                    }

                    node = new CleanupNode(
                        relativePath,
                        fullPath,
                        identity,
                        handle,
                        ownsHandle);
                    handle = null;
                    if (identity.IsDirectory)
                    {
                        node.Children = SnapshotTargetChildren(
                            fullPath,
                            relativePath,
                            seen);
                    }
                    else if (String.Equals(
                        relativePath,
                        MarkerFileName,
                        StringComparison.OrdinalIgnoreCase))
                    {
                        string marker = ReadUtf8File(
                            node.Handle,
                            ExpectedMarkerContents.Length + 8,
                            "owned marker");
                        if (!String.Equals(
                            marker,
                            ExpectedMarkerContents,
                            StringComparison.Ordinal))
                        {
                            throw new InvalidOperationException(
                                "Owned marker runID or token mismatch");
                        }
                    }
                    result.Add(node);
                    node = null;
                }
                finally
                {
                    if (node != null)
                    {
                        node.Dispose();
                    }
                    if (ownsHandle && handle != null)
                    {
                        handle.Dispose();
                    }
                }
            }
            return result;
        }
        catch
        {
            DisposeCleanupNodes(result);
            throw;
        }
    }

    private void ValidateCleanupEntrySets(
        string directoryPath,
        List<CleanupNode> children)
    {
        List<string> currentNames = EnumerateNames(directoryPath);
        if (currentNames.Count != children.Count)
        {
            throw new InvalidOperationException(
                "A target directory changed after its safe inventory");
        }

        HashSet<string> expectedNames = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < children.Count; index++)
        {
            expectedNames.Add(Path.GetFileName(children[index].FullPath));
        }
        for (int index = 0; index < currentNames.Count; index++)
        {
            if (!expectedNames.Contains(currentNames[index]))
            {
                throw new InvalidOperationException(
                    "A target directory gained an unknown entry");
            }
        }

        for (int index = 0; index < children.Count; index++)
        {
            CleanupNode child = children[index];
            FileIdentity identity = ReadIdentity(
                child.Handle,
                "inventoried target child " + child.RelativePath);
            RequirePlainEntry(identity, "inventoried target child " + child.RelativePath);
            RequireSameIdentity(
                child.Identity,
                identity,
                "An inventoried target child changed identity");
            if (identity.IsDirectory)
            {
                ValidateCleanupEntrySets(child.FullPath, child.Children);
            }
        }
    }

    private void DeleteCleanupNode(CleanupNode node)
    {
        FileIdentity identity = ReadIdentity(
            node.Handle,
            "target child before disposition " + node.RelativePath);
        RequirePlainEntry(identity, "target child before disposition " + node.RelativePath);
        RequireSameIdentity(
            node.Identity,
            identity,
            "Target child changed before disposition: " + node.RelativePath);

        if (identity.IsDirectory)
        {
            for (int index = 0; index < node.Children.Count; index++)
            {
                DeleteCleanupNode(node.Children[index]);
            }
            node.Children.Clear();
            if (EnumerateNames(node.FullPath).Count != 0)
            {
                throw new InvalidOperationException(
                    "Directory gained an entry during cleanup: " + node.RelativePath);
            }
        }

        SetDeleteDisposition(node.Handle, "target child " + node.RelativePath);
        if (identity.IsDirectory)
        {
            ownedDirectoryHandles.Remove(node.RelativePath);
        }
        node.Handle.Dispose();
        node.Handle = null;
    }

    private void CopySourceNode(SourceNode source, string targetParent)
    {
        string targetPath = Path.Combine(targetParent, source.Name);
        string relativePath = source.RelativePath;
        if (expectedEntries.ContainsKey(relativePath))
        {
            throw new InvalidOperationException(
                "Case-colliding or reserved source path refused: " + relativePath);
        }

        if (source.Identity.IsDirectory)
        {
            if (!NativeMethods.CreateDirectory(ToExtendedPath(targetPath), IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateDirectoryW failed for " + relativePath);
            }

            SafeKernelHandle directoryHandle = null;
            try
            {
                directoryHandle = OpenHandle(
                    targetPath,
                    DeleteAccess | FileReadAttributes,
                    FileShareRead,
                    FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                    "new target directory " + relativePath);
                FileIdentity identity = ReadIdentity(
                    directoryHandle,
                    "new target directory " + relativePath);
                RequirePlainDirectory(identity, "new target directory " + relativePath);
                expectedEntries.Add(
                    relativePath,
                    new ExpectedEntry(relativePath, identity, true));
                ownedDirectoryHandles.Add(relativePath, directoryHandle);
                directoryHandle = null;

                for (int index = 0; index < source.Children.Count; index++)
                {
                    CopySourceNode(source.Children[index], targetPath);
                }
            }
            finally
            {
                if (directoryHandle != null)
                {
                    directoryHandle.Dispose();
                }
            }
            return;
        }

        SafeKernelHandle targetFile = null;
        try
        {
            targetFile = CreateNewFileHandle(
                targetPath,
                GenericWrite | DeleteAccess | FileReadAttributes,
                "new target file " + relativePath);
            FileIdentity identity = ReadIdentity(
                targetFile,
                "new target file " + relativePath);
            RequirePlainFile(identity, "new target file " + relativePath);
            expectedEntries.Add(
                relativePath,
                new ExpectedEntry(relativePath, identity, false));

            CopyHandleContents(source.Handle, targetFile, relativePath);
            if (!NativeMethods.FlushFileBuffers(targetFile))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "FlushFileBuffers failed for " + relativePath);
            }
        }
        finally
        {
            if (targetFile != null)
            {
                targetFile.Dispose();
            }
        }
    }

    private static SourceNode SnapshotSourceTree(string sourcePath)
    {
        SafeKernelHandle rootHandle = OpenHandle(
            sourcePath,
            FileListDirectory | FileReadAttributes,
            FileShareRead,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint,
            "source root");
        SourceNode root = null;
        try
        {
            FileIdentity identity = ReadIdentity(rootHandle, "source root");
            RequirePlainDirectory(identity, "source root");
            root = new SourceNode(
                String.Empty,
                String.Empty,
                sourcePath,
                identity,
                rootHandle);
            rootHandle = null;
            PopulateSourceChildren(root);
            SourceNode completed = root;
            root = null;
            return completed;
        }
        finally
        {
            if (root != null)
            {
                root.Dispose();
            }
            if (rootHandle != null)
            {
                rootHandle.Dispose();
            }
        }
    }

    private static void PopulateSourceChildren(SourceNode directory)
    {
        List<string> names = EnumerateNames(directory.FullPath);
        for (int index = 0; index < names.Count; index++)
        {
            string name = names[index];
            string relativePath = CombineRelative(directory.RelativePath, name);
            if (String.Equals(
                name,
                MarkerFileName,
                StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "The source contains the reserved owned-mount marker name");
            }

            string fullPath = Path.Combine(directory.FullPath, name);
            uint findAttributes = ReadPathAttributes(fullPath);
            bool findDirectory = (findAttributes & FileAttributeDirectory) != 0;
            uint access = FileReadAttributes |
                (findDirectory ? FileListDirectory : GenericRead);
            uint flags = FileFlagOpenReparsePoint |
                (findDirectory ? FileFlagBackupSemantics : FileFlagSequentialScan);
            SafeKernelHandle handle = OpenHandle(
                fullPath,
                access,
                FileShareRead,
                flags,
                "source entry " + relativePath);
            SourceNode child = null;
            try
            {
                FileIdentity identity = ReadIdentity(
                    handle,
                    "source entry " + relativePath);
                RequirePlainEntry(identity, "source entry " + relativePath);
                if (identity.IsDirectory != findDirectory)
                {
                    throw new InvalidOperationException(
                        "Source entry type changed while opening: " + relativePath);
                }
                if (!identity.IsDirectory && identity.NumberOfLinks != 1)
                {
                    throw new InvalidOperationException(
                        "Hard-linked source file refused: " + relativePath);
                }

                child = new SourceNode(
                    name,
                    relativePath,
                    fullPath,
                    identity,
                    handle);
                handle = null;
                if (identity.IsDirectory)
                {
                    PopulateSourceChildren(child);
                }
                directory.Children.Add(child);
                child = null;
            }
            finally
            {
                if (child != null)
                {
                    child.Dispose();
                }
                if (handle != null)
                {
                    handle.Dispose();
                }
            }
        }
    }

    private static void ValidateStableSourceTree(SourceNode directory)
    {
        List<string> names = EnumerateNames(directory.FullPath);
        if (names.Count != directory.Children.Count)
        {
            throw new InvalidOperationException(
                "The source directory changed during its safe inventory");
        }
        HashSet<string> expected = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < directory.Children.Count; index++)
        {
            expected.Add(directory.Children[index].Name);
        }
        for (int index = 0; index < names.Count; index++)
        {
            if (!expected.Contains(names[index]))
            {
                throw new InvalidOperationException(
                    "The source gained an unknown entry during inventory");
            }
        }

        for (int index = 0; index < directory.Children.Count; index++)
        {
            SourceNode child = directory.Children[index];
            FileIdentity identity = ReadIdentity(
                child.Handle,
                "inventoried source " + child.RelativePath);
            RequirePlainEntry(identity, "inventoried source " + child.RelativePath);
            RequireSameIdentity(
                child.Identity,
                identity,
                "Source entry changed identity: " + child.RelativePath);
            if (identity.IsDirectory)
            {
                ValidateStableSourceTree(child);
            }
        }
    }

    private static FileIdentity CreateMarkerFile(string path, string contents)
    {
        SafeKernelHandle handle = null;
        bool complete = false;
        try
        {
            handle = CreateNewFileHandle(
                path,
                GenericWrite | DeleteAccess | FileReadAttributes,
                "owned marker");
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(contents);
            WriteAll(handle, bytes, "owned marker");
            if (!NativeMethods.FlushFileBuffers(handle))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "FlushFileBuffers failed for the owned marker");
            }
            FileIdentity identity = ReadIdentity(handle, "owned marker");
            RequirePlainFile(identity, "owned marker");
            complete = true;
            return identity;
        }
        finally
        {
            if (!complete && handle != null && !handle.IsInvalid)
            {
                try { SetDeleteDisposition(handle, "incomplete owned marker"); }
                catch { }
            }
            if (handle != null)
            {
                handle.Dispose();
            }
        }
    }

    private static void CopyHandleContents(
        SafeKernelHandle source,
        SafeKernelHandle target,
        string relativePath)
    {
        byte[] buffer = new byte[64 * 1024];
        while (true)
        {
            uint read;
            if (!NativeMethods.ReadFile(
                source,
                buffer,
                (uint)buffer.Length,
                out read,
                IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "ReadFile failed for " + relativePath);
            }
            if (read == 0)
            {
                return;
            }

            int offset = 0;
            while (offset < read)
            {
                uint written;
                int remaining = checked((int)read - offset);
                byte[] slice;
                if (offset == 0)
                {
                    slice = buffer;
                }
                else
                {
                    slice = new byte[remaining];
                    Buffer.BlockCopy(buffer, offset, slice, 0, remaining);
                }
                if (!NativeMethods.WriteFile(
                    target,
                    slice,
                    (uint)remaining,
                    out written,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "WriteFile failed for " + relativePath);
                }
                if (written == 0)
                {
                    throw new IOException(
                        "WriteFile made no progress for " + relativePath);
                }
                offset += checked((int)written);
            }
        }
    }

    private static void WriteAll(
        SafeKernelHandle target,
        byte[] bytes,
        string description)
    {
        int offset = 0;
        while (offset < bytes.Length)
        {
            int remaining = bytes.Length - offset;
            byte[] slice;
            if (offset == 0)
            {
                slice = bytes;
            }
            else
            {
                slice = new byte[remaining];
                Buffer.BlockCopy(bytes, offset, slice, 0, remaining);
            }
            uint written;
            if (!NativeMethods.WriteFile(
                target,
                slice,
                (uint)remaining,
                out written,
                IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "WriteFile failed for " + description);
            }
            if (written == 0)
            {
                throw new IOException(
                    "WriteFile made no progress for " + description);
            }
            offset += checked((int)written);
        }
    }

    private static string ReadUtf8File(
        SafeKernelHandle handle,
        int maximumBytes,
        string description)
    {
        long size;
        if (!NativeMethods.GetFileSizeEx(handle, out size))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "GetFileSizeEx failed for " + description);
        }
        if (size < 0 || size > maximumBytes)
        {
            throw new InvalidOperationException(
                description + " has an unexpected length");
        }

        byte[] bytes = new byte[checked((int)size)];
        int offset = 0;
        while (offset < bytes.Length)
        {
            byte[] slice = new byte[bytes.Length - offset];
            uint read;
            if (!NativeMethods.ReadFile(
                handle,
                slice,
                (uint)slice.Length,
                out read,
                IntPtr.Zero))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "ReadFile failed for " + description);
            }
            if (read == 0)
            {
                throw new EndOfStreamException(
                    "Unexpected end of " + description);
            }
            Buffer.BlockCopy(slice, 0, bytes, offset, checked((int)read));
            offset += checked((int)read);
        }
        return new UTF8Encoding(false, true).GetString(bytes);
    }

    private static List<string> EnumerateNames(string directoryPath)
    {
        List<string> names = new List<string>();
        string pattern = ToExtendedPath(directoryPath).TrimEnd('\\') + "\\*";
        WIN32_FIND_DATA data;
        SafeFindHandle find = NativeMethods.FindFirstFile(pattern, out data);
        if (find.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            find.Dispose();
            if (error == ErrorFileNotFound)
            {
                return names;
            }
            throw new Win32Exception(error, "FindFirstFileW failed for " + directoryPath);
        }

        using (find)
        {
            while (true)
            {
                string name = data.cFileName;
                if (!String.Equals(name, ".", StringComparison.Ordinal) &&
                    !String.Equals(name, "..", StringComparison.Ordinal))
                {
                    if (String.IsNullOrEmpty(name) ||
                        name.IndexOf('\\') >= 0 ||
                        name.IndexOf('/') >= 0)
                    {
                        throw new InvalidOperationException(
                            "An invalid directory entry name was returned");
                    }
                    names.Add(name);
                }

                if (!NativeMethods.FindNextFile(find, out data))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 18)
                    {
                        break;
                    }
                    throw new Win32Exception(
                        error,
                        "FindNextFileW failed for " + directoryPath);
                }
            }
        }
        return names;
    }

    private static uint ReadPathAttributes(string path)
    {
        SafeKernelHandle handle = null;
        try
        {
            handle = OpenHandle(
                path,
                FileReadAttributes,
                FileShareRead | FileShareWrite | FileShareDelete,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                "path attribute inspection");
            return ReadIdentity(handle, "path attribute inspection").Attributes;
        }
        finally
        {
            if (handle != null)
            {
                handle.Dispose();
            }
        }
    }

    private static void AssertPathContainsNoReparsePoint(
        string path,
        bool requireFinalDirectory)
    {
        string fullPath = Path.GetFullPath(path);
        string pathRoot = Path.GetPathRoot(fullPath);
        if (String.IsNullOrEmpty(pathRoot))
        {
            throw new ArgumentException("The path must be absolute", "path");
        }

        List<string> components = new List<string>();
        components.Add(pathRoot);
        string remainder = fullPath.Substring(pathRoot.Length);
        string[] parts = remainder.Split(
            new char[] { '\\', '/' },
            StringSplitOptions.RemoveEmptyEntries);
        string current = pathRoot;
        for (int index = 0; index < parts.Length; index++)
        {
            current = Path.Combine(current, parts[index]);
            components.Add(current);
        }

        for (int index = 0; index < components.Count; index++)
        {
            SafeKernelHandle handle = null;
            try
            {
                handle = OpenHandle(
                    components[index],
                    FileReadAttributes,
                    FileShareRead | FileShareWrite | FileShareDelete,
                    FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                    "path component " + components[index]);
                FileIdentity identity = ReadIdentity(
                    handle,
                    "path component " + components[index]);
                if (identity.IsReparsePoint)
                {
                    throw new InvalidOperationException(
                        "Reparse path component refused: " + components[index]);
                }
                if (index < components.Count - 1 && !identity.IsDirectory)
                {
                    throw new InvalidOperationException(
                        "Non-directory path component refused: " + components[index]);
                }
                if (index == components.Count - 1 &&
                    requireFinalDirectory &&
                    !identity.IsDirectory)
                {
                    throw new InvalidOperationException(
                        "Expected a directory: " + components[index]);
                }
            }
            finally
            {
                if (handle != null)
                {
                    handle.Dispose();
                }
            }
        }
    }

    private static List<SafeKernelHandle> OpenDirectoryGuards(
        string rootPath,
        string descendantPath)
    {
        List<SafeKernelHandle> handles = new List<SafeKernelHandle>();
        try
        {
            string current = rootPath;
            SafeKernelHandle rootHandle = OpenHandle(
                current,
                FileReadAttributes,
                FileShareRead | FileShareWrite,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                "root path guard");
            handles.Add(rootHandle);
            RequirePlainDirectory(
                ReadIdentity(rootHandle, "root path guard"),
                "root path guard");

            string remainder = descendantPath.Substring(rootPath.Length)
                .TrimStart('\\', '/');
            string[] parts = remainder.Split(
                new char[] { '\\', '/' },
                StringSplitOptions.RemoveEmptyEntries);
            for (int index = 0; index < parts.Length; index++)
            {
                current = Path.Combine(current, parts[index]);
                SafeKernelHandle handle = OpenHandle(
                    current,
                    FileReadAttributes,
                    FileShareRead | FileShareWrite,
                    FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                    "directory path guard");
                handles.Add(handle);
                FileIdentity identity = ReadIdentity(handle, "directory path guard");
                RequirePlainDirectory(identity, "directory path guard");
            }
            return handles;
        }
        catch
        {
            DisposeHandles(handles);
            throw;
        }
    }

    private static SafeKernelHandle CreateNewFileHandle(
        string path,
        uint access,
        string description)
    {
        SafeKernelHandle handle = NativeMethods.CreateFile(
            ToExtendedPath(path),
            access,
            FileShareRead,
            IntPtr.Zero,
            CreateNew,
            FileAttributeNormal | FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "CreateFileW failed for " + description);
        }
        return handle;
    }

    private static SafeKernelHandle OpenHandle(
        string path,
        uint access,
        uint share,
        uint flags,
        string description)
    {
        SafeKernelHandle handle = NativeMethods.CreateFile(
            ToExtendedPath(path),
            access,
            share,
            IntPtr.Zero,
            OpenExisting,
            flags,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "CreateFileW failed for " + description);
        }
        return handle;
    }

    private static FileIdentity ReadIdentity(
        SafeKernelHandle handle,
        string description)
    {
        BY_HANDLE_FILE_INFORMATION information;
        if (!NativeMethods.GetFileInformationByHandle(handle, out information))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "GetFileInformationByHandle failed for " + description);
        }

        FILE_ID_INFO fileIdInformation;
        if (!NativeMethods.GetFileInformationByHandleEx(
            handle,
            FileIdInfo,
            out fileIdInformation,
            (uint)Marshal.SizeOf(typeof(FILE_ID_INFO))))
        {
            // A platform without FILE_ID_INFO cannot meet the ownership proof;
            // do not silently fall back to BY_HANDLE_FILE_INFORMATION's 64 bits.
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "GetFileInformationByHandleEx(FileIdInfo) failed for " + description);
        }
        return new FileIdentity(
            fileIdInformation.VolumeSerialNumber,
            fileIdInformation.FileId.LowPart,
            fileIdInformation.FileId.HighPart,
            information.FileAttributes,
            information.NumberOfLinks);
    }

    private static void SetDeleteDisposition(
        SafeKernelHandle handle,
        string description)
    {
        FILE_DISPOSITION_INFO disposition = new FILE_DISPOSITION_INFO();
        disposition.DeleteFile = 1;
        if (!NativeMethods.SetFileInformationByHandle(
            handle,
            FileDispositionInfo,
            ref disposition,
            (uint)Marshal.SizeOf(typeof(FILE_DISPOSITION_INFO))))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "FileDispositionInfo failed for " + description);
        }
    }

    private static void RequireSameIdentity(
        FileIdentity expected,
        FileIdentity actual,
        string message)
    {
        if (expected.VolumeSerialNumber != actual.VolumeSerialNumber ||
            expected.FileIdLow != actual.FileIdLow ||
            expected.FileIdHigh != actual.FileIdHigh)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void RequirePlainEntry(FileIdentity identity, string description)
    {
        if (identity.IsReparsePoint)
        {
            throw new InvalidOperationException(
                "Reparse point refused: " + description);
        }
        if ((identity.Attributes & FileAttributeDevice) != 0)
        {
            throw new InvalidOperationException(
                "Device entry refused: " + description);
        }
    }

    private static void RequirePlainDirectory(FileIdentity identity, string description)
    {
        RequirePlainEntry(identity, description);
        if (!identity.IsDirectory)
        {
            throw new InvalidOperationException(description + " is not a directory");
        }
    }

    private static void RequirePlainFile(FileIdentity identity, string description)
    {
        RequirePlainEntry(identity, description);
        if (identity.IsDirectory)
        {
            throw new InvalidOperationException(description + " is not a file");
        }
        if (identity.NumberOfLinks != 1)
        {
            throw new InvalidOperationException(
                "Hard-linked file refused: " + description);
        }
    }

    private static string NormalizeExistingDirectory(string path, string parameterName)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException(
                "An explicit absolute directory is required",
                parameterName);
        }
        if (path.IndexOf('\0') >= 0 || !IsExplicitFullyQualifiedPath(path))
        {
            throw new ArgumentException(
                "The directory must be an absolute path without NUL characters",
                parameterName);
        }
        string fullPath = Path.GetFullPath(path);
        string pathRoot = Path.GetPathRoot(fullPath);
        if (fullPath.Length > pathRoot.Length)
        {
            fullPath = fullPath.TrimEnd('\\', '/');
        }
        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException(
                "Directory does not exist: " + fullPath);
        }
        return fullPath;
    }

    private static bool IsExplicitFullyQualifiedPath(string path)
    {
        if (path.StartsWith("\\\\?\\", StringComparison.Ordinal) ||
            path.StartsWith("\\\\.\\", StringComparison.Ordinal))
        {
            return false;
        }

        bool driveAbsolute = path.Length >= 3 &&
            ((path[0] >= 'A' && path[0] <= 'Z') ||
             (path[0] >= 'a' && path[0] <= 'z')) &&
            path[1] == ':' &&
            (path[2] == '\\' || path[2] == '/');
        if (driveAbsolute)
        {
            return true;
        }

        if (!path.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return false;
        }
        string uncRoot = Path.GetPathRoot(path);
        return !String.IsNullOrEmpty(uncRoot) && uncRoot.Length > 2;
    }

    private static bool IsStrictlyUnder(string candidate, string root)
    {
        string prefix = root.TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
        return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static bool PathsOverlap(string first, string second)
    {
        if (String.Equals(first, second, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        return IsStrictlyUnder(first, second) || IsStrictlyUnder(second, first);
    }

    private string ValidateGeneratedRelativePath(string relativePath)
    {
        if (String.IsNullOrWhiteSpace(relativePath) ||
            relativePath.IndexOf('\0') >= 0 ||
            Path.IsPathRooted(relativePath))
        {
            throw new ArgumentException(
                "Generated path must be a non-empty relative path",
                "relativePath");
        }

        string[] parts = relativePath.Split(
            new char[] { '\\', '/' },
            StringSplitOptions.None);
        if (parts.Length == 0)
        {
            throw new ArgumentException("Generated path is empty", "relativePath");
        }
        char[] invalid = Path.GetInvalidFileNameChars();
        for (int index = 0; index < parts.Length; index++)
        {
            string part = parts[index];
            if (String.IsNullOrEmpty(part) ||
                String.Equals(part, ".", StringComparison.Ordinal) ||
                String.Equals(part, "..", StringComparison.Ordinal) ||
                part.IndexOfAny(invalid) >= 0 ||
                String.Equals(part, MarkerFileName, StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "Generated path contains an invalid or reserved component",
                    "relativePath");
            }
        }

        string normalized = String.Join(
            Path.DirectorySeparatorChar.ToString(),
            parts);
        string fullPath = Path.GetFullPath(Path.Combine(TargetPath, normalized));
        if (!IsStrictlyUnder(fullPath, TargetPath))
        {
            throw new ArgumentException(
                "Generated path escapes the owned target",
                "relativePath");
        }
        return normalized;
    }

    private static string CombineRelative(string parent, string name)
    {
        return String.IsNullOrEmpty(parent) ? name : Path.Combine(parent, name);
    }

    private static string BuildMarkerContents(string runId, string mountToken)
    {
        return "SOURCE_ORACLE_OWNED_MOUNT_V1\n" +
            "run_id=" + runId + "\n" +
            "mount_token=" + mountToken + "\n";
    }

    private static void ValidateRunId(string runId)
    {
        if (runId == null || runId.Length != 32)
        {
            throw new ArgumentException(
                "runID must be exactly 32 lowercase hexadecimal characters",
                "runId");
        }
        for (int index = 0; index < runId.Length; index++)
        {
            char value = runId[index];
            if (!((value >= '0' && value <= '9') ||
                (value >= 'a' && value <= 'f')))
            {
                throw new ArgumentException(
                    "runID must be exactly 32 lowercase hexadecimal characters",
                    "runId");
            }
        }
    }

    private static string ToExtendedPath(string path)
    {
        if (path.StartsWith("\\\\?\\", StringComparison.Ordinal))
        {
            return path;
        }
        if (path.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return "\\\\?\\UNC\\" + path.Substring(2);
        }
        return "\\\\?\\" + path;
    }

    private void ThrowIfUnavailable()
    {
        if (disposed)
        {
            throw new ObjectDisposedException("SourceOracleOwnedMount");
        }
        if (cleaned || targetHandle == null)
        {
            throw new InvalidOperationException("The owned mount has already been cleaned");
        }
    }

    private static void DisposeHandles(List<SafeKernelHandle> handles)
    {
        if (handles == null)
        {
            return;
        }
        for (int index = handles.Count - 1; index >= 0; index--)
        {
            if (handles[index] != null)
            {
                handles[index].Dispose();
            }
        }
        handles.Clear();
    }

    private static void DisposeCleanupNodes(List<CleanupNode> nodes)
    {
        if (nodes == null)
        {
            return;
        }
        for (int index = 0; index < nodes.Count; index++)
        {
            nodes[index].Dispose();
        }
        nodes.Clear();
    }

    private sealed class ExpectedEntry
    {
        internal ExpectedEntry(
            string relativePath,
            FileIdentity identity,
            bool isDirectory)
        {
            RelativePath = relativePath;
            Identity = identity;
            IsDirectory = isDirectory;
        }

        internal string RelativePath;
        internal FileIdentity Identity;
        internal bool IsDirectory;
    }

    private sealed class SourceNode : IDisposable
    {
        internal SourceNode(
            string name,
            string relativePath,
            string fullPath,
            FileIdentity identity,
            SafeKernelHandle handle)
        {
            Name = name;
            RelativePath = relativePath;
            FullPath = fullPath;
            Identity = identity;
            Handle = handle;
            Children = new List<SourceNode>();
        }

        internal string Name;
        internal string RelativePath;
        internal string FullPath;
        internal FileIdentity Identity;
        internal SafeKernelHandle Handle;
        internal List<SourceNode> Children;

        public void Dispose()
        {
            for (int index = 0; index < Children.Count; index++)
            {
                Children[index].Dispose();
            }
            Children.Clear();
            if (Handle != null)
            {
                Handle.Dispose();
                Handle = null;
            }
        }
    }

    private sealed class CleanupNode : IDisposable
    {
        internal CleanupNode(
            string relativePath,
            string fullPath,
            FileIdentity identity,
            SafeKernelHandle handle,
            bool ownsHandle)
        {
            RelativePath = relativePath;
            FullPath = fullPath;
            Identity = identity;
            Handle = handle;
            OwnsHandle = ownsHandle;
            Children = new List<CleanupNode>();
        }

        internal string RelativePath;
        internal string FullPath;
        internal FileIdentity Identity;
        internal SafeKernelHandle Handle;
        internal bool OwnsHandle;
        internal List<CleanupNode> Children;

        public void Dispose()
        {
            for (int index = 0; index < Children.Count; index++)
            {
                Children[index].Dispose();
            }
            Children.Clear();
            if (OwnsHandle && Handle != null)
            {
                Handle.Dispose();
                Handle = null;
            }
        }
    }

    private sealed class FileIdentity
    {
        internal FileIdentity(
            ulong volumeSerialNumber,
            ulong fileIdLow,
            ulong fileIdHigh,
            uint attributes,
            uint numberOfLinks)
        {
            VolumeSerialNumber = volumeSerialNumber;
            FileIdLow = fileIdLow;
            FileIdHigh = fileIdHigh;
            Attributes = attributes;
            NumberOfLinks = numberOfLinks;
        }

        internal ulong VolumeSerialNumber;
        internal ulong FileIdLow;
        internal ulong FileIdHigh;
        internal uint Attributes;
        internal uint NumberOfLinks;

        internal bool IsDirectory
        {
            get { return (Attributes & FileAttributeDirectory) != 0; }
        }

        internal bool IsReparsePoint
        {
            get { return (Attributes & FileAttributeReparsePoint) != 0; }
        }
    }

    private sealed class SafeKernelHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeKernelHandle()
            : base(true)
        {
        }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.CloseHandle(handle);
        }
    }

    private sealed class SafeFindHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeFindHandle()
            : base(true)
        {
        }

        protected override bool ReleaseHandle()
        {
            return NativeMethods.FindClose(handle);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint LowDateTime;
        public uint HighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ID_128
    {
        public ulong LowPart;
        public ulong HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ID_INFO
    {
        public ulong VolumeSerialNumber;
        public FILE_ID_128 FileId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public FILETIME ftCreationTime;
        public FILETIME ftLastAccessTime;
        public FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_DISPOSITION_INFO
    {
        // WinBase.h defines this field as BOOLEAN, not the four-byte BOOL.
        public byte DeleteFile;
    }

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateDirectory(
            string path,
            IntPtr securityAttributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeKernelHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileInformationByHandle(
            SafeKernelHandle file,
            out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileInformationByHandleEx(
            SafeKernelHandle file,
            int informationClass,
            out FILE_ID_INFO information,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetFileInformationByHandle(
            SafeKernelHandle file,
            int informationClass,
            ref FILE_DISPOSITION_INFO information,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ReadFile(
            SafeKernelHandle file,
            byte[] buffer,
            uint bytesToRead,
            out uint bytesRead,
            IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool WriteFile(
            SafeKernelHandle file,
            byte[] buffer,
            uint bytesToWrite,
            out uint bytesWritten,
            IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FlushFileBuffers(SafeKernelHandle file);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetFileSizeEx(
            SafeKernelHandle file,
            out long fileSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFindHandle FindFirstFile(
            string pattern,
            out WIN32_FIND_DATA findData);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FindNextFile(
            SafeFindHandle find,
            out WIN32_FIND_DATA findData);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool FindClose(IntPtr findHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);
    }
}
