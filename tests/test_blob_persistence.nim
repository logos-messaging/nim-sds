import std/[base64, json, tables]
import stew/byteutils
import chronos, results
import sds
import sds/persistence/blob_store
import ./async_unittest

const testChannel = "testChannel"

type BlobTable = ref object
  meta: Table[string, seq[byte]]
  history: Table[string, seq[byte]]
  loaded: Table[string, seq[byte]]
  dropped: int

proc newBlobStore(t: BlobTable): BlobStore =
  BlobStore(
    saveChannelMeta: proc(
        channelId: SdsChannelID, blob: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []).} =
      {.cast(raises: []).}:
        t.meta[channelId] = blob
      return ok(),
    updateHistory: proc(
        channelId: SdsChannelID, blob: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []).} =
      {.cast(raises: []).}:
        t.history[channelId] = blob
      return ok(),
    loadChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[seq[byte], string]] {.async: (raises: []).} =
      {.cast(raises: []).}:
        return ok(t.loaded.getOrDefault(channelId)),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      t.dropped.inc()
      return ok(),
  )

suite "BlobStore persistence":
  asyncTest "empty load blob yields an empty channel":
    let persistence = newBlobPersistence(newBlobStore(BlobTable()))
    let channel = (await persistence.loadChannel(testChannel)).get()
    check:
      channel.messageHistory.len == 0

  asyncTest "malformed load blob is reported":
    let t = BlobTable()
    t.loaded[testChannel] = @[byte('{')]
    let persistence = newBlobPersistence(newBlobStore(t))
    check (await persistence.loadChannel(testChannel)).isErr()

  asyncTest "history and meta written by the adapter load back":
    let t = BlobTable()
    let persistence = newBlobPersistence(newBlobStore(t))

    var meta = ChannelMeta.init()
    meta.lamportTimestamp = 42
    check (await persistence.saveChannelMeta(testChannel, meta)).isOk()

    var update = HistoryUpdate.init()
    update.append.add(
      SdsMessage.init("msg-1", 7, @[], testChannel, @[1.byte, 2, 3], @[])
    )
    check (await persistence.updateHistory(testChannel, update)).isOk()

    # A store assembles the load blob from the two blobs written above.
    let written = parseJson(string.fromBytes(t.history[testChannel]))
    let loadBlob =
      %*{
        "meta": base64.encode(string.fromBytes(t.meta[testChannel])),
        "messageHistory": [written["append"][0]["data"].getStr()],
      }
    t.loaded[testChannel] = toBytes($loadBlob)

    let channel = (await persistence.loadChannel(testChannel)).get()
    check:
      channel.meta.lamportTimestamp == 42
      channel.messageHistory.len == 1
      channel.messageHistory[0].messageId == "msg-1"
      channel.messageHistory[0].content == @[1.byte, 2, 3]

  asyncTest "dropChannel reaches the store":
    let t = BlobTable()
    let persistence = newBlobPersistence(newBlobStore(t))
    check (await persistence.dropChannel(testChannel)).isOk()
    check t.dropped == 1
