# Agent wire protocol

The client talks to `remote-agent.cjs` over one SSH channel (stdin/stdout). The channel starts in
JSON lines. A client that sends `{"id":N,"op":"frames","params":{"version":1}}` gets the line
`{"id":N,"result":{"version":1,"chunk":262144,"window":1048576}}`. From then on both directions
use binary frames. The client sends nothing else after the upgrade line until that reply arrives.

## Frame

```
[u32 length][u8 type][u32 id][payload]     big endian; length = 5 + payload bytes, at most 1 MiB + 1024
```

| type | id | payload |
| --- | --- | --- |
| 1 JSON | 0 | a UTF-8 JSON message, the same shape as one JSON line (requests, replies, events, `cancel`) |
| 2 BLOB | request id | `[u32 n][n bytes JSON reply][raw bytes]`. `preview` uses it instead of base64 `inlineData`; the reply has `inlineBytes: <length>` |
| 3 DATA | stream id | file bytes, at most `chunk` |
| 4 END | stream id | empty when the sender finished; otherwise a UTF-8 error |
| 5 CREDIT | stream id | `[u32 bytes]` the receiver can accept on top of what it already allowed |

The stream id is the id of the request that opened it. A sender never has more than its credit in flight,
so a control message never waits behind more than about one window of file data.

## Download: `file` / `read`

`params`: `path`, `base`, optional `version` (refuse when it changed), `offset` (resume), `window` (initial credit, at most 4 MiB).
Reply: `{size, version, offset}`. Then DATA frames from `offset`, then END. The file is checked again at the end;
a change gives an END error. `{"cancel": id}` stops the stream with END `已取消`.

## Upload: `file` / `write`

`params`: the fields of the old `transfer upload` request (`attachment`, `digest`, `name`, `directory`, `size`).
The agent answers with JSON `{"stream":id,"offset":n}`. `n > 0` only for an attachment whose partial upload
(same digest) is still on the server; the client sends from there. Then it sends CREDIT; the client sends DATA within it and END.
The final reply `{id, result}` is the stored file's metadata, as before.
