"""Independent PyArrow oracle for the pure Zig producer (test dependency only)."""
import ctypes as ct
import gc
import pathlib
import sys
import pyarrow as pa


class ArrowArray(ct.Structure):
    _fields_ = [
        ("length", ct.c_int64), ("null_count", ct.c_int64), ("offset", ct.c_int64),
        ("n_buffers", ct.c_int64), ("n_children", ct.c_int64),
        ("buffers", ct.POINTER(ct.c_void_p)), ("children", ct.c_void_p),
        ("dictionary", ct.c_void_p), ("release", ct.c_void_p), ("private_data", ct.c_void_p),
    ]


class ArrowSchema(ct.Structure):
    _fields_ = [
        ("format", ct.c_char_p), ("name", ct.c_char_p), ("metadata", ct.c_void_p),
        ("flags", ct.c_int64), ("n_children", ct.c_int64), ("children", ct.c_void_p),
        ("dictionary", ct.c_void_p), ("release", ct.c_void_p), ("private_data", ct.c_void_p),
    ]


def release(value):
    if value.release:
        ct.CFUNCTYPE(None, ct.c_void_p)(value.release)(ct.addressof(value))
        assert not value.release


lib = ct.CDLL(str(pathlib.Path(sys.argv[1]).resolve()))
lib.arrowz_fixture.argtypes = [ct.c_uint32, ct.c_uint32, ct.POINTER(ArrowArray), ct.POINTER(ArrowSchema)]
lib.arrowz_fixture.restype = ct.c_int
lib.arrowz_abi_size.argtypes = [ct.c_uint32]
lib.arrowz_abi_size.restype = ct.c_size_t
lib.arrowz_abi_offset.argtypes = [ct.c_uint32, ct.c_uint32]
lib.arrowz_abi_offset.restype = ct.c_size_t
for kind, cls in enumerate((ArrowArray, ArrowSchema)):
    assert lib.arrowz_abi_size(kind) == ct.sizeof(cls)
    for i, (name, _) in enumerate(cls._fields_):
        assert lib.arrowz_abi_offset(kind, i) == getattr(cls, name).offset

types = [pa.int8(), pa.uint8(), pa.int16(), pa.uint16(), pa.int32(), pa.uint32(),
         pa.int64(), pa.uint64(), pa.float32(), pa.float64(), pa.bool_()]
cases = 0
for kind, dtype in enumerate(types):
    for scenario in range(5):
        raw, schema = ArrowArray(), ArrowSchema()
        assert lib.arrowz_fixture(kind, scenario, ct.byref(raw), ct.byref(schema)) == 0
        address = raw.buffers[1]
        validity = raw.buffers[0]
        expected = [] if scenario == 0 else [
            None if scenario == 2 or (scenario >= 3 and i % 3 == 0)
            else (i % 2 == 0 if kind == 10 else i) for i in range(20)
        ]
        if scenario == 4:
            expected = expected[7:16]
        try:
            # Releasing the schema independently must not invalidate the values.
            imported_type = pa.DataType._import_from_c(ct.addressof(schema))
            assert not schema.release
            assert imported_type == dtype
            arr = pa.Array._import_from_c(ct.addressof(raw), imported_type)
            assert not raw.release
            assert arr.to_pylist() == expected, (dtype, scenario, arr.to_pylist())
            arr.validate(full=True)
            if expected:
                assert arr.buffers()[1].address == address, "value data copied"
                if validity:
                    assert arr.buffers()[0].address == validity, "validity data copied"
            assert arr.offset == (7 if scenario == 4 else 0)
            del arr
            gc.collect()
        finally:
            release(raw)
            release(schema)
        cases += 1
print(f"PASS: {cases} native Zig -> PyArrow {pa.__version__} cases; ABI fields, types, nulls, offsets, zero-copy, release")
