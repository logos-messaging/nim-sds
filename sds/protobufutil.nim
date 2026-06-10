# Minimal hand-rolled protobuf field codec, a thin shim over
# `nim-protobuf-serialization`'s low-level wire `codec` module.
#
# `sds/protobuf.nim` and `sds/snapshot_codec.nim` build messages by hand at the
# field level — including a backward-compatible decode path the type-driven
# `Protobuf.encode/decode` API cannot express, and required-field / always-write
# semantics its default-value omission would break — so this exposes a small
# accumulating `ProtoBuffer` with `write`/`getField`/`getRepeatedField`/`finish`:
#   * unsigned integers encode as plain varints (last value wins on decode);
#   * strings and byte seqs encode length-delimited, with no UTF-8 validation
#     (strings are treated as opaque bytes — message ids may be binary);
#   * a field whose stored wire type differs from the requested one is skipped,
#     as `protoc` does; only a malformed buffer yields an error.
#
# On construction from bytes the buffer is parsed once, in a single forward pass
# with the library's reader, into per-field value lists; the `getField` accessors
# are then plain lookups rather than re-scanning the buffer for every field.

{.push raises: [].}

import std/tables
import results
import faststreams/inputs
from protobuf_serialization/codec import
  FieldHeader, WireKind, init, number, kind, toBytes, readHeader, readValue,
  skipValue, puint64, pbytes, fixed64, fixed32
import ./types/protobuf_error

export results, protobuf_error

type ProtoBuffer* = object ## Accumulating protobuf field buffer.
  buffer*: seq[byte]
  ## Reads are served from these parse-once indexes (populated by `init(data)`),
  ## keyed by field number; values are kept in wire order so last-wins / repeated
  ## semantics fall out directly.
  varints: Table[int, seq[uint64]]
  lengthDelims: Table[int, seq[seq[byte]]]
  parseOk: bool

converter toProtobufError*(err: ProtoError): ProtobufError =
  case err
  of ProtoError.RequiredFieldMissing:
    return ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: "unknown")
  else:
    return ProtobufError(kind: ProtobufErrorKind.DecodeFailure, error: err)

proc missingRequiredField*(T: type ProtobufError, field: string): T =
  return ProtobufError.init(field)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc init*(T: type ProtoBuffer): T =
  return T(buffer: @[], parseOk: true)

proc init*(T: type ProtoBuffer, data: seq[byte]): T =
  ## Parse `data` once into per-field value lists. A malformed buffer leaves
  ## `parseOk = false`, which every accessor reports as a decode error.
  var pb = T(buffer: data, parseOk: true)
  var sh = memoryInput(data)
  try:
    let stream = sh.s
    while stream.readable:
      let hdr = readHeader(stream)
      case hdr.kind
      of WireKind.Varint:
        pb.varints.mgetOrPut(hdr.number, @[]).add(uint64(readValue(stream, puint64)))
      of WireKind.LengthDelim:
        pb.lengthDelims.mgetOrPut(hdr.number, @[]).add(seq[byte](readValue(stream, pbytes)))
      of WireKind.Fixed64:
        skipValue(stream, fixed64)
      of WireKind.Fixed32:
        skipValue(stream, fixed32)
  except CatchableError:
    pb.parseOk = false
  return pb

proc finish*(pb: var ProtoBuffer) =
  ## No length prefix is used, so finishing only asserts the invariant that a
  ## top-level buffer is never empty.
  doAssert(pb.buffer.len > 0)

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

proc writeVarint(pb: var ProtoBuffer, field: int, value: uint64) =
  pb.buffer.add(toBytes(FieldHeader.init(field, WireKind.Varint)))
  pb.buffer.add(toBytes(puint64(value)))

proc write*(pb: var ProtoBuffer, field: int, value: uint64) =
  pb.writeVarint(field, value)

proc write*(pb: var ProtoBuffer, field: int, value: uint32) =
  pb.writeVarint(field, uint64(value))

proc writeLengthDelim(pb: var ProtoBuffer, field: int, data: openArray[byte]) =
  pb.buffer.add(toBytes(FieldHeader.init(field, WireKind.LengthDelim)))
  pb.buffer.add(toBytes(puint64(uint64(data.len))))
  if data.len > 0:
    pb.buffer.add(data)

proc write*(pb: var ProtoBuffer, field: int, value: openArray[byte]) =
  pb.writeLengthDelim(field, value)

proc write*(pb: var ProtoBuffer, field: int, value: string) =
  pb.writeLengthDelim(field, value.toOpenArrayByte(0, value.high))

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc bytesToString(b: seq[byte]): string =
  ## Copy raw bytes into a string without UTF-8 validation — protobuf strings
  ## are opaque bytes here, and message ids may not be valid UTF-8.
  var s = newString(b.len)
  if b.len > 0:
    copyMem(addr s[0], unsafeAddr b[0], b.len)
  return s

proc getField*(pb: ProtoBuffer, field: int, output: var uint64): ProtoResult[bool] =
  if not pb.parseOk:
    return err(ProtoError.VarintDecode)
  let values = pb.varints.getOrDefault(field)
  if values.len > 0:
    output = values[^1]
    return ok(true)
  return ok(false)

proc getField*(pb: ProtoBuffer, field: int, output: var uint32): ProtoResult[bool] =
  if not pb.parseOk:
    return err(ProtoError.VarintDecode)
  let values = pb.varints.getOrDefault(field)
  if values.len > 0:
    output = uint32(values[^1])
    return ok(true)
  return ok(false)

proc getField*(pb: ProtoBuffer, field: int, output: var seq[byte]): ProtoResult[bool] =
  if not pb.parseOk:
    return err(ProtoError.VarintDecode)
  let values = pb.lengthDelims.getOrDefault(field)
  if values.len > 0:
    output = values[^1]
    return ok(true)
  return ok(false)

proc getField*(pb: ProtoBuffer, field: int, output: var string): ProtoResult[bool] =
  if not pb.parseOk:
    return err(ProtoError.VarintDecode)
  let values = pb.lengthDelims.getOrDefault(field)
  if values.len > 0:
    output = bytesToString(values[^1])
    return ok(true)
  return ok(false)

proc getRepeatedField*(
    pb: ProtoBuffer, field: int, output: var seq[seq[byte]]
): ProtoResult[bool] =
  if not pb.parseOk:
    return err(ProtoError.VarintDecode)
  output = pb.lengthDelims.getOrDefault(field)
  return ok(output.len > 0)

proc getRepeatedField*(
    pb: ProtoBuffer, field: int, output: var seq[string]
): ProtoResult[bool] =
  if not pb.parseOk:
    return err(ProtoError.VarintDecode)
  let values = pb.lengthDelims.getOrDefault(field)
  output.setLen(0)
  for v in values:
    output.add(bytesToString(v))
  return ok(output.len > 0)

{.pop.}
