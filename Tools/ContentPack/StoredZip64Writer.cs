using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

// Independent streaming STORED/Zip64 writer. Framework ZipArchive's
// NoCompression may still emit method 8, which cannot support nested VPK seeks.
public sealed class GarrysPADStoredZip64Writer : IDisposable
{
    internal sealed class Record {
        internal byte[] Name; internal long Offset, Length; internal uint Crc;
        internal ushort Time, Date;
    }
    public sealed class Entry {
        private readonly GarrysPADStoredZip64Writer owner; private readonly string name;
        private bool opened;
        public DateTimeOffset LastWriteTime { get; set; }
        internal Entry(GarrysPADStoredZip64Writer writer, string path) { owner = writer; name = path; LastWriteTime = DateTimeOffset.Now; }
        public Stream Open() {
            if (opened) throw new InvalidOperationException("Entry already opened");
            opened = true; return owner.Open(name, LastWriteTime);
        }
    }
    private readonly BinaryWriter writer;
    private readonly Stream output;
    private readonly List<Record> records = new List<Record>();
    private bool active, disposed;
    private static readonly uint[] Table = MakeTable();
    public GarrysPADStoredZip64Writer(Stream stream) {
        if (!stream.CanSeek || !stream.CanWrite) throw new ArgumentException("Seekable output required");
        output = stream; writer = new BinaryWriter(stream, Encoding.UTF8, true);
    }
    public Entry CreateEntry(string name, object unusedCompressionLevel) {
        if (disposed) throw new ObjectDisposedException("ZIP writer");
        return new Entry(this, name);
    }
    private Stream Open(string name, DateTimeOffset timestamp) {
        if (active || disposed) throw new InvalidOperationException("Invalid ZIP entry lifetime");
        byte[] bytes = Encoding.UTF8.GetBytes(name);
        if (bytes.Length == 0 || bytes.Length > ushort.MaxValue) throw new ArgumentException("Invalid ZIP name");
        var time = timestamp.LocalDateTime;
        if (time.Year < 1980 || time.Year > 2107) time = new DateTime(1980, 1, 1);
        var record = new Record { Name = bytes, Offset = output.Position,
            Time = (ushort)((time.Hour << 11) | (time.Minute << 5) | (time.Second / 2)),
            Date = (ushort)(((time.Year - 1980) << 9) | (time.Month << 5) | time.Day) };
        writer.Write(0x04034b50u); writer.Write((ushort)45); writer.Write((ushort)0x800);
        writer.Write((ushort)0); writer.Write(record.Time); writer.Write(record.Date);
        writer.Write(0u); writer.Write(uint.MaxValue); writer.Write(uint.MaxValue);
        writer.Write((ushort)bytes.Length); writer.Write((ushort)20); writer.Write(bytes);
        writer.Write((ushort)1); writer.Write((ushort)16); writer.Write(0L); writer.Write(0L);
        active = true; return new PayloadStream(this, record);
    }
    private void Finish(Record record) {
        long end = output.Position;
        output.Position = record.Offset + 14; writer.Write(record.Crc);
        output.Position = record.Offset + 30 + record.Name.Length + 4;
        writer.Write(record.Length); writer.Write(record.Length);
        output.Position = end; records.Add(record); active = false;
    }
    public void Dispose() {
        if (disposed) return;
        if (active) throw new InvalidOperationException("Close the active ZIP payload first");
        disposed = true;
        long start = output.Position;
        foreach (var r in records) {
            writer.Write(0x02014b50u); writer.Write((ushort)45); writer.Write((ushort)45);
            writer.Write((ushort)0x800); writer.Write((ushort)0); writer.Write(r.Time); writer.Write(r.Date);
            writer.Write(r.Crc); writer.Write(uint.MaxValue); writer.Write(uint.MaxValue);
            writer.Write((ushort)r.Name.Length); writer.Write((ushort)28); writer.Write((ushort)0);
            writer.Write((ushort)0); writer.Write((ushort)0); writer.Write(0u); writer.Write(uint.MaxValue);
            writer.Write(r.Name); writer.Write((ushort)1); writer.Write((ushort)24);
            writer.Write(r.Length); writer.Write(r.Length); writer.Write(r.Offset);
        }
        long length = output.Position - start, zip64End = output.Position;
        writer.Write(0x06064b50u); writer.Write(44L); writer.Write((ushort)45); writer.Write((ushort)45);
        writer.Write(0u); writer.Write(0u); writer.Write((long)records.Count); writer.Write((long)records.Count);
        writer.Write(length); writer.Write(start);
        writer.Write(0x07064b50u); writer.Write(0u); writer.Write(zip64End); writer.Write(1u);
        writer.Write(0x06054b50u); writer.Write((ushort)0); writer.Write((ushort)0);
        writer.Write(ushort.MaxValue); writer.Write(ushort.MaxValue);
        writer.Write(uint.MaxValue); writer.Write(uint.MaxValue); writer.Write((ushort)0);
        writer.Flush(); writer.Dispose();
    }
    private static uint[] MakeTable() {
        var table = new uint[256];
        for (uint i = 0; i < 256; i++) { uint value = i; for (int bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320u : value >> 1; table[i] = value; }
        return table;
    }
    private sealed class PayloadStream : Stream {
        private readonly GarrysPADStoredZip64Writer owner; private readonly Record record;
        private uint crc = uint.MaxValue; private bool closed;
        internal PayloadStream(GarrysPADStoredZip64Writer writer, Record entry) { owner = writer; record = entry; }
        public override void Write(byte[] buffer, int offset, int count) {
            if (closed) throw new ObjectDisposedException("ZIP payload");
            if (buffer == null || offset < 0 || count < 0 || offset > buffer.Length - count) throw new ArgumentException("Invalid buffer range");
            owner.output.Write(buffer, offset, count);
            for (int i = offset; i < offset + count; i++) crc = Table[(crc ^ buffer[i]) & 255] ^ (crc >> 8);
            record.Length = checked(record.Length + count);
        }
        protected override void Dispose(bool disposing) { if (!closed) { closed = true; record.Crc = crc ^ uint.MaxValue; owner.Finish(record); } base.Dispose(disposing); }
        public override bool CanRead { get { return false; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return !closed; } }
        public override long Length { get { return record.Length; } }
        public override long Position { get { return record.Length; } set { throw new NotSupportedException(); } }
        public override void Flush() { owner.output.Flush(); }
        public override int Read(byte[] b, int o, int c) { throw new NotSupportedException(); }
        public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
        public override void SetLength(long l) { throw new NotSupportedException(); }
    }
}
