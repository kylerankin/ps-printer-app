#!/usr/bin/env python3
"""Minimal IPP/2.0 client for the appliance tests.

It sends one request from the host to a printer URI and prints the response
so the caller can check it without trusting any client tool in the image:

    status=0x0000
    attribute-name=value[,value...]

Usage:
    ipp-request.py PRINTER_URI get-printer-attributes
    ipp-request.py PRINTER_URI print-job FILE MIME_TYPE [NAME=KEYWORD ...]
    ipp-request.py PRINTER_URI get-job-attributes JOB_ID
    ipp-request.py SYSTEM_URI get-system-attributes

Each NAME=KEYWORD after a print-job's MIME_TYPE is sent as a keyword job
template attribute, e.g. a printer's secure-printing=on.

ipp:// maps to http:// on the same host and port (RFC 8010, section 4).
"""
import struct
import sys
import urllib.request

OPERATIONS = {
    "print-job": 0x0002,
    "get-job-attributes": 0x0009,
    "get-printer-attributes": 0x000B,
    "get-system-attributes": 0x005B,
}
TEXT_TAGS = range(0x40, 0x50)
INTEGER_TAGS = (0x21, 0x23)


def attribute(tag: int, name: str, value) -> bytes:
    if isinstance(value, int):
        data = struct.pack(">i", value)
    else:
        data = value.encode("utf-8")
    encoded = name.encode("ascii")
    return (
        struct.pack(">BH", tag, len(encoded))
        + encoded
        + struct.pack(">H", len(data))
        + data
    )


def decode(tag: int, data: bytes) -> str:
    if tag in INTEGER_TAGS and len(data) == 4:
        return str(struct.unpack(">i", data)[0])
    if tag == 0x22 and len(data) == 1:
        return "true" if data[0] else "false"
    if tag in TEXT_TAGS:
        return data.decode("utf-8", "replace")
    return data.hex()


def parse(body: bytes):
    if len(body) < 8:
        raise ValueError(f"short IPP response ({len(body)} bytes)")
    status = struct.unpack(">H", body[2:4])[0]
    attributes: dict[str, list[str]] = {}
    offset, name = 8, ""
    while offset < len(body):
        tag = body[offset]
        offset += 1
        if tag == 0x03:
            break
        if tag < 0x10:
            continue
        name_length = struct.unpack(">H", body[offset:offset + 2])[0]
        offset += 2
        if name_length:
            name = body[offset:offset + name_length].decode("ascii", "replace")
        offset += name_length
        value_length = struct.unpack(">H", body[offset:offset + 2])[0]
        offset += 2
        value = body[offset:offset + value_length]
        offset += value_length
        attributes.setdefault(name, []).append(decode(tag, value))
    return status, attributes


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[2] not in OPERATIONS:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    uri, operation = sys.argv[1], sys.argv[2]
    if not uri.startswith("ipp://"):
        print(f"not an ipp:// URI: {uri}", file=sys.stderr)
        return 2

    request = struct.pack(">BBHI", 2, 0, OPERATIONS[operation], 1) + bytes([0x01])
    request += attribute(0x47, "attributes-charset", "utf-8")
    request += attribute(0x48, "attributes-natural-language", "en")
    # System operations address the system object (PWG 5100.22, section 4).
    target = "system-uri" if operation == "get-system-attributes" else "printer-uri"
    request += attribute(0x45, target, uri)
    request += attribute(0x42, "requesting-user-name", "appliance-test")
    document = b""
    if operation == "print-job":
        if len(sys.argv) < 5:
            print("print-job needs FILE and MIME_TYPE", file=sys.stderr)
            return 2
        request += attribute(0x42, "job-name", "appliance-test")
        request += attribute(0x49, "document-format", sys.argv[4])
        job_attributes = b""
        for setting in sys.argv[5:]:
            name, separator, value = setting.partition("=")
            if not name or not separator or not value:
                print(f"job attribute is not NAME=KEYWORD: {setting}", file=sys.stderr)
                return 2
            job_attributes += attribute(0x44, name, value)
        if job_attributes:
            request += bytes([0x02]) + job_attributes
        with open(sys.argv[3], "rb") as handle:
            document = handle.read()
    elif operation == "get-job-attributes":
        if len(sys.argv) != 4:
            print("get-job-attributes needs JOB_ID", file=sys.stderr)
            return 2
        request += attribute(0x21, "job-id", int(sys.argv[3]))
    elif len(sys.argv) != 3:
        print(f"{operation} takes no further arguments", file=sys.stderr)
        return 2
    request += bytes([0x03]) + document

    http = urllib.request.Request(
        "http://" + uri[len("ipp://"):],
        data=request,
        headers={"Content-Type": "application/ipp"},
        method="POST",
    )
    with urllib.request.urlopen(http, timeout=60) as response:
        body = response.read()
        content_type = response.headers.get("Content-Type", "")
    if not content_type.startswith("application/ipp"):
        print(f"not an IPP response: Content-Type {content_type!r}", file=sys.stderr)
        return 1

    status, attributes = parse(body)
    print(f"status=0x{status:04x}")
    for name, values in attributes.items():
        print(f"{name}={','.join(values)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
