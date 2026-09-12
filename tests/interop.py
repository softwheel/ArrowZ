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


class ArrowArrayStream(ct.Structure):
    _fields_ = [
        ("get_schema", ct.c_void_p), ("get_next", ct.c_void_p),
        ("get_last_error", ct.c_void_p), ("release", ct.c_void_p),
        ("private_data", ct.c_void_p),
    ]


def release(value):
    if value.release:
        ct.CFUNCTYPE(None, ct.c_void_p)(value.release)(ct.addressof(value))
        assert not value.release


lib = ct.CDLL(str(pathlib.Path(sys.argv[1]).resolve()))
lib.arrowz_fixture.argtypes = [ct.c_uint32, ct.c_uint32, ct.POINTER(ArrowArray), ct.POINTER(ArrowSchema)]
lib.arrowz_fixture.restype = ct.c_int
lib.arrowz_import_fixture.argtypes = [ct.c_uint32, ct.c_uint32, ct.POINTER(ArrowArray), ct.POINTER(ArrowSchema)]
lib.arrowz_import_fixture.restype = ct.c_int
lib.arrowz_take_fixture.argtypes = [ct.c_uint32, ct.c_uint32, ct.POINTER(ArrowArray), ct.POINTER(ArrowSchema)]
lib.arrowz_take_fixture.restype = ct.c_int
lib.arrowz_stream_fixture.argtypes = [ct.c_uint32, ct.POINTER(ArrowArrayStream)]
lib.arrowz_stream_fixture.restype = ct.c_int
lib.arrowz_batch_fixture.argtypes = [ct.POINTER(ArrowArray), ct.POINTER(ArrowSchema)]
lib.arrowz_batch_fixture.restype = ct.c_int
lib.arrowz_nested_batch_fixture.argtypes = [ct.POINTER(ArrowArray), ct.POINTER(ArrowSchema)]
lib.arrowz_nested_batch_fixture.restype = ct.c_int
lib.arrowz_abi_size.argtypes = [ct.c_uint32]
lib.arrowz_abi_size.restype = ct.c_size_t
lib.arrowz_abi_offset.argtypes = [ct.c_uint32, ct.c_uint32]
lib.arrowz_abi_offset.restype = ct.c_size_t
for kind, cls in enumerate((ArrowArray, ArrowSchema, ArrowArrayStream)):
    assert lib.arrowz_abi_size(kind) == ct.sizeof(cls)
    for i, (name, _) in enumerate(cls._fields_):
        assert lib.arrowz_abi_offset(kind, i) == getattr(cls, name).offset

types = [pa.int8(), pa.uint8(), pa.int16(), pa.uint16(), pa.int32(), pa.uint32(),
         pa.int64(), pa.uint64(), pa.float32(), pa.float64(), pa.bool_(),
         pa.binary(), pa.string()]
cases = 0
for kind, dtype in enumerate(types):
    for scenario in range(5):
        raw, schema = ArrowArray(), ArrowSchema()
        assert lib.arrowz_fixture(kind, scenario, ct.byref(raw), ct.byref(schema)) == 0
        address = raw.buffers[1]
        data_address = raw.buffers[2] if kind >= 11 else None
        validity = raw.buffers[0]
        if kind == 11:
            values = [b"", b"\x00\xff", b"abc"]
        elif kind == 12:
            values = ["", "数据", "🏹"]
        else:
            values = None
        expected = [] if scenario == 0 else [
            None if scenario == 2 or (scenario >= 3 and i % 3 == 0)
            else (values[i % 3] if values is not None else (i % 2 == 0 if kind == 10 else i))
            for i in range(20)
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
                if data_address:
                    assert arr.buffers()[2].address == data_address, "variable data copied"
            assert arr.offset == (7 if scenario == 4 else 0)
            del arr
            gc.collect()
        finally:
            release(raw)
            release(schema)
        cases += 1

# PyArrow supplies each leaf schema and chunk through independent Python C Stream
# callbacks. Zig owns/releases schema, chunk, and stream on separate timelines.
GET_SCHEMA = ct.CFUNCTYPE(ct.c_int, ct.c_void_p, ct.c_void_p)
GET_NEXT = ct.CFUNCTYPE(ct.c_int, ct.c_void_p, ct.c_void_p)
GET_LAST_ERROR = ct.CFUNCTYPE(ct.c_char_p, ct.c_void_p)
RELEASE_STREAM = ct.CFUNCTYPE(None, ct.c_void_p)
for kind, dtype in enumerate(types):
    if kind == 11:
        values = [b"", b"\x00\xff", b"abc"]
    elif kind == 12:
        values = ["", "数据", "🏹"]
    else:
        values = None
    source_values = [
        None if i % 3 == 0
        else (values[i % 3] if values is not None else (i % 2 == 0 if kind == 10 else i))
        for i in range(20)
    ]
    chunk = pa.array(source_values, type=dtype)
    counts = {"schema": 0, "next": 0, "error": 0, "release": 0}

    @GET_SCHEMA
    def get_schema(_stream, out):
        counts["schema"] += 1
        dtype._export_to_c(out)
        return 0

    @GET_NEXT
    def get_next(_stream, out):
        counts["next"] += 1
        if counts["next"] == 1:
            chunk._export_to_c(out)
        return 0

    @GET_LAST_ERROR
    def get_last_error(_stream):
        counts["error"] += 1
        return None

    @RELEASE_STREAM
    def release_stream(stream_pointer):
        counts["release"] += 1
        ct.cast(stream_pointer, ct.POINTER(ArrowArrayStream)).contents.release = None

    stream = ArrowArrayStream(
        ct.cast(get_schema, ct.c_void_p), ct.cast(get_next, ct.c_void_p),
        ct.cast(get_last_error, ct.c_void_p), ct.cast(release_stream, ct.c_void_p), None,
    )
    assert lib.arrowz_stream_fixture(kind, ct.byref(stream)) == 0, dtype
    assert not stream.release
    assert counts == {"schema": 1, "next": 2, "error": 0, "release": 1}, (dtype, counts)
    cases += 1

# Ownership direction: PyArrow produces both base structures, Zig moves them,
# validates through its native view, and invokes each producer callback on exit.
for kind, dtype in enumerate(types):
    for scenario in range(5):
        if kind == 11:
            values = [b"", b"\x00\xff", b"abc"]
        elif kind == 12:
            values = ["", "数据", "🏹"]
        else:
            values = None
        source_values = [] if scenario == 0 else [
            None if scenario == 2 or (scenario >= 3 and i % 3 == 0)
            else (values[i % 3] if values is not None else (i % 2 == 0 if kind == 10 else i))
            for i in range(20)
        ]
        source = pa.array(source_values, type=dtype)
        if scenario == 4:
            source = source.slice(7, 9)
        raw, schema = ArrowArray(), ArrowSchema()
        source._export_to_c(ct.addressof(raw), ct.addressof(schema))
        assert lib.arrowz_take_fixture(kind, scenario, ct.byref(raw), ct.byref(schema)) == 0, (dtype, scenario)
        assert not raw.release and not schema.release, "Zig take did not invalidate moved sources"
        cases += 1

# Inverse direction: PyArrow is the independent producer and Zig borrows every
# supported leaf layout without consuming either producer-owned base structure.
for kind, dtype in enumerate(types):
    for scenario in range(5):
        if kind == 11:
            values = [b"", b"\x00\xff", b"abc"]
        elif kind == 12:
            values = ["", "数据", "🏹"]
        else:
            values = None
        source_values = [] if scenario == 0 else [
            None if scenario == 2 or (scenario >= 3 and i % 3 == 0)
            else (values[i % 3] if values is not None else (i % 2 == 0 if kind == 10 else i))
            for i in range(20)
        ]
        source = pa.array(source_values, type=dtype)
        if scenario == 4:
            source = source.slice(7, 9)
        raw, schema = ArrowArray(), ArrowSchema()
        source._export_to_c(ct.addressof(raw), ct.addressof(schema))
        try:
            assert lib.arrowz_import_fixture(kind, scenario, ct.byref(raw), ct.byref(schema)) == 0, (dtype, scenario)
            assert raw.release and schema.release, "borrowed Zig import consumed producer ownership"
        finally:
            release(raw)
            release(schema)
        cases += 1

raw, schema = ArrowArray(), ArrowSchema()
assert lib.arrowz_batch_fixture(ct.byref(raw), ct.byref(schema)) == 0
children = ct.cast(raw.children, ct.POINTER(ct.POINTER(ArrowArray)))
child_addresses = [children[i].contents.buffers[1] for i in range(3)]
name_data_address = children[1].contents.buffers[2]
try:
    imported_schema = pa.Schema._import_from_c(ct.addressof(schema))
    assert not schema.release
    assert imported_schema.names == ["id", "name", "active"]
    assert imported_schema.types == [pa.int32(), pa.string(), pa.bool_()]
    assert not imported_schema.field(0).nullable
    assert imported_schema.field(0).metadata == {b"role": b"key"}
    assert imported_schema.metadata == {b"source": b"arrowz"}
    batch = pa.RecordBatch._import_from_c(ct.addressof(raw), imported_schema)
    assert not raw.release
    assert batch.to_pydict() == {
        "id": [10, 11, 12, 13],
        "name": ["zero", None, "数据", ""],
        "active": [True, False, None, True],
    }
    batch.validate(full=True)
    assert batch.column(0).buffers()[1].address == child_addresses[0]
    assert batch.column(1).buffers()[1].address == child_addresses[1]
    assert batch.column(1).buffers()[2].address == name_data_address
    assert batch.column(2).buffers()[1].address == child_addresses[2]
    del batch
    gc.collect()
finally:
    release(raw)
    release(schema)
cases += 1

raw, schema = ArrowArray(), ArrowSchema()
assert lib.arrowz_nested_batch_fixture(ct.byref(raw), ct.byref(schema)) == 0
root_children = ct.cast(raw.children, ct.POINTER(ct.POINTER(ArrowArray)))
outer_raw = root_children[0].contents
outer_children = ct.cast(outer_raw.children, ct.POINTER(ct.POINTER(ArrowArray)))
inner_raw = outer_children[0].contents
label_raw = outer_children[1].contents
inner_children = ct.cast(inner_raw.children, ct.POINTER(ct.POINTER(ArrowArray)))
id_raw = inner_children[0].contents
addresses = {
    "outer_validity": outer_raw.buffers[0],
    "inner_validity": inner_raw.buffers[0],
    "id_values": id_raw.buffers[1],
    "label_offsets": label_raw.buffers[1],
    "label_data": label_raw.buffers[2],
}
try:
    imported_schema = pa.Schema._import_from_c(ct.addressof(schema))
    assert not schema.release
    outer_field = imported_schema.field("outer")
    assert outer_field.metadata == {b"level": b"outer"}
    assert outer_field.type.field("inner").metadata == {b"level": b"inner"}
    assert not outer_field.type.field("inner").type.field("id").nullable
    assert imported_schema.metadata == {b"source": b"arrowz-nested"}
    batch = pa.RecordBatch._import_from_c(ct.addressof(raw), imported_schema)
    assert not raw.release
    assert batch.column(0).to_pylist() == [
        None,
        {"inner": None, "label": None},
        {"inner": {"id": 42}, "label": "two"},
    ]
    batch.validate(full=True)
    outer = batch.column(0)
    inner = outer.field(0)
    assert outer.buffers()[0].address == addresses["outer_validity"]
    assert inner.buffers()[0].address == addresses["inner_validity"]
    assert inner.field(0).buffers()[1].address == addresses["id_values"]
    assert outer.field(1).buffers()[1].address == addresses["label_offsets"]
    assert outer.field(1).buffers()[2].address == addresses["label_data"]
    del batch, outer, inner
    gc.collect()
finally:
    release(raw)
    release(schema)
cases += 1
print(f"PASS: {cases} native Zig C Data/Stream and PyArrow {pa.__version__} cases; ABI fields, types, nulls, offsets, zero-copy, release")
