"""Streaming repair for .NET Framework NoCompression archives (method 8).

Creates a new ZIP; never replaces the source or an existing destination.
Python 3 standard library only. The content manifest and payload are unchanged.
"""
import argparse
import shutil
import zipfile
from pathlib import Path, PurePosixPath


def convert(source, destination):
    if source.resolve() == destination.resolve():
        raise ValueError("Source and destination must differ")
    with zipfile.ZipFile(source) as incoming:
        entries = incoming.infolist()
        seen = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            key = entry.filename.casefold()
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename or key in seen:
                raise ValueError("Unsafe or duplicate entry: " + entry.filename)
            seen.add(key)
        with destination.open("xb") as output:
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as outgoing:
                for index, entry in enumerate(entries, 1):
                    info = zipfile.ZipInfo(entry.filename, entry.date_time)
                    info.compress_type = zipfile.ZIP_STORED
                    info.external_attr = entry.external_attr
                    info.file_size = entry.file_size
                    with incoming.open(entry) as reader, outgoing.open(info, "w", force_zip64=True) as writer:
                        shutil.copyfileobj(reader, writer, length=4 * 1024 * 1024)
                    if index % 250 == 0 or index == len(entries):
                        print(f"Stored {index}/{len(entries)}", flush=True)
    print(destination, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    convert(args.source, args.destination)
