"""HID LampArray access over hidraw for the ASUS/ITE keyboard RGB controller.

Stdlib only. The controller on the Vivobook S 14 (ITE5570, 0B05:19B6) exposes a
LampArray collection (HID usage page 0x59) as FEATURE reports. Report ids are
resolved from the report descriptor at runtime, with the ids seen on this
device as the fallback, since sibling models use different numbering.
"""

import fcntl
import glob
import json
import os
import struct

VENDOR_ASUS = 0x0B05
KNOWN_PRODUCTS = {0x19B6, 0x5570}
LAMPARRAY_PAGE = 0x59

# LampArray usage ids (HID Usage Tables, section 25)
USAGE_ATTRIBUTES_REPORT = 0x02
USAGE_LAMP_ATTR_REQUEST = 0x20
USAGE_LAMP_ATTR_RESPONSE = 0x22
USAGE_MULTI_UPDATE = 0x50
USAGE_RANGE_UPDATE = 0x60
USAGE_CONTROL = 0x70

DEFAULT_IDS = {"attrs": 0x01, "lampReq": 0x02, "lampResp": 0x03,
               "multi": 0x04, "range": 0x05, "control": 0x0B}

CACHE_PATH = os.path.expanduser("~/.cache/vivobook/lamparray.json")

_IOC_NRBITS, _IOC_TYPEBITS, _IOC_SIZEBITS = 8, 8, 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_WRITE, _IOC_READ = 1, 2


def _ioc(direction, typ, nr, size):
    return ((direction << _IOC_DIRSHIFT) | (ord(typ) << _IOC_TYPESHIFT)
            | (nr << _IOC_NRSHIFT) | (size << _IOC_SIZESHIFT))


def hidiocgrdescsize():
    return _ioc(_IOC_READ, 'H', 0x01, 4)


def hidiocgrdesc():
    return _ioc(_IOC_READ, 'H', 0x02, 4 + 4096)


def hidiocgrawinfo():
    return _ioc(_IOC_READ, 'H', 0x03, 8)


def hidiocsfeature(n):
    return _ioc(_IOC_WRITE | _IOC_READ, 'H', 0x06, n)


def hidiocgfeature(n):
    return _ioc(_IOC_WRITE | _IOC_READ, 'H', 0x07, n)


class LampArrayError(Exception):
    pass


def raw_info(fd):
    buf = bytearray(8)
    fcntl.ioctl(fd, hidiocgrawinfo(), buf)
    bustype, vendor, product = struct.unpack("<Ihh", buf)
    return bustype, vendor & 0xFFFF, product & 0xFFFF


def report_descriptor(fd):
    size = bytearray(4)
    fcntl.ioctl(fd, hidiocgrdescsize(), size)
    (n,) = struct.unpack("<I", size)
    buf = bytearray(4 + 4096)
    struct.pack_into("<I", buf, 0, n)
    fcntl.ioctl(fd, hidiocgrdesc(), buf)
    return bytes(buf[4:4 + n])


def parse_report_ids(desc):
    """Walk the descriptor and map LampArray usages to report ids.

    Returns a dict like DEFAULT_IDS (only the keys found) plus a boolean
    'lamparray' saying whether a 0x59 collection exists at all.
    """
    ids = {}
    found_page = False
    usage_page = None
    report_id = None
    pending_usages = []
    i = 0
    while i < len(desc):
        prefix = desc[i]
        i += 1
        if prefix == 0xFE:  # long item
            length = desc[i]
            i += 2 + length
            continue
        size = prefix & 0x03
        size = 4 if size == 3 else size
        typ = (prefix >> 2) & 0x03
        tag = (prefix >> 4) & 0x0F
        data = int.from_bytes(desc[i:i + size], "little") if size else 0
        i += size
        if typ == 1:  # global
            if tag == 0:
                usage_page = data
                if data == LAMPARRAY_PAGE:
                    found_page = True
            elif tag == 8:
                report_id = data
        elif typ == 2:  # local
            if tag == 0:
                pending_usages.append((usage_page, data))
        elif typ == 0:  # main
            if tag == 10:  # collection: its usage names the report (Report ID precedes it)
                for page, usage in pending_usages:
                    if page == LAMPARRAY_PAGE:
                        _remember(ids, usage, report_id)
                pending_usages = []
            elif tag in (8, 9, 11):  # input / output / feature
                for page, usage in pending_usages:
                    if page == LAMPARRAY_PAGE and report_id is not None:
                        _remember(ids, usage, report_id)
                pending_usages = []
            elif tag == 12:  # end collection
                pending_usages = []
    ids["lamparray"] = found_page
    return ids


_USAGE_TO_KEY = {
    USAGE_ATTRIBUTES_REPORT: "attrs",
    USAGE_LAMP_ATTR_REQUEST: "lampReq",
    USAGE_LAMP_ATTR_RESPONSE: "lampResp",
    USAGE_MULTI_UPDATE: "multi",
    USAGE_RANGE_UPDATE: "range",
    USAGE_CONTROL: "control",
}


def _remember(ids, usage, report_id):
    key = _USAGE_TO_KEY.get(usage)
    if key and report_id is not None and key not in ids:
        ids[key] = report_id


def find_device_path():
    """Return the hidraw node of the LampArray controller, or None."""
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(path, "device", "uevent")) as f:
                uevent = f.read()
        except OSError:
            continue
        hid_id = ""
        for line in uevent.splitlines():
            if line.startswith("HID_ID="):
                hid_id = line.split("=", 1)[1]
        parts = hid_id.split(":")
        if len(parts) != 3:
            continue
        vendor, product = int(parts[1], 16), int(parts[2], 16)
        if vendor == VENDOR_ASUS and product in KNOWN_PRODUCTS:
            return "/dev/" + os.path.basename(path)
    return None


def device_accessible(path=None):
    path = path or find_device_path()
    return bool(path) and os.access(path, os.R_OK | os.W_OK)


class LampArray:
    def __init__(self, path=None):
        self.path = path or find_device_path()
        if not self.path:
            raise LampArrayError("no LampArray keyboard controller found")
        try:
            self.fd = os.open(self.path, os.O_RDWR)
        except PermissionError as e:
            raise LampArrayError(f"{self.path} is not writable (run setup.sh)") from e
        try:
            desc = report_descriptor(self.fd)
            parsed = parse_report_ids(desc)
        except OSError:
            parsed = {"lamparray": True}
        self.ids = dict(DEFAULT_IDS)
        for k, v in parsed.items():
            if k in self.ids:
                self.ids[k] = v
        self.lamparray = parsed.get("lamparray", True)
        self._lamp_count = None

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _set_feature(self, payload):
        buf = bytearray(payload)
        fcntl.ioctl(self.fd, hidiocsfeature(len(buf)), buf)

    def _get_feature(self, report_id, length):
        buf = bytearray(length)
        buf[0] = report_id
        fcntl.ioctl(self.fd, hidiocgfeature(len(buf)), buf)
        return bytes(buf)

    def attributes(self):
        raw = self._get_feature(self.ids["attrs"], 23)
        _, count, w, h, d, kind, interval = struct.unpack("<BHIIIII", raw[:23])
        self._lamp_count = count
        attrs = {"lampCount": count, "widthUm": w, "heightUm": h, "depthUm": d,
                 "kind": kind, "minUpdateIntervalUs": interval, "reportIds": self.ids,
                 "device": self.path}
        _write_cache(attrs)
        return attrs

    @property
    def lamp_count(self):
        if self._lamp_count is None:
            cached = _read_cache()
            if cached and cached.get("device") == self.path and cached.get("lampCount"):
                self._lamp_count = cached["lampCount"]
            else:
                try:
                    self.attributes()
                except OSError:
                    self._lamp_count = 1
        return max(1, self._lamp_count)

    def control(self, autonomous):
        self._set_feature(struct.pack("<BB", self.ids["control"], 1 if autonomous else 0))

    def range_update(self, start, end, r, g, b, intensity=255, complete=True):
        self._set_feature(struct.pack("<BBHHBBBB", self.ids["range"], 1 if complete else 0,
                                      start, end, r & 0xFF, g & 0xFF, b & 0xFF, intensity & 0xFF))

    def set_all(self, r, g, b, intensity=255):
        """Take host control and paint every lamp one color."""
        self.control(False)
        self.range_update(0, self.lamp_count - 1, r, g, b, intensity)

    def autonomous(self):
        """Hand lighting back to the firmware's built-in effect."""
        self.control(True)


def _read_cache():
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_cache(attrs):
    try:
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        with open(CACHE_PATH, "w") as f:
            json.dump(attrs, f)
    except OSError:
        pass


def hex_to_rgb(value):
    value = value.strip().lstrip("#")
    if len(value) != 6:
        raise ValueError("color must be RRGGBB")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))
