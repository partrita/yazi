# ftp.yazi

Browse and download from FTP/FTPS servers directly inside [Yazi](https://github.com/sxyazi/yazi),
using the custom VFS provider API and a `curl` backend.

No changes to Yazi's source code are required.

## Requirements

- A Yazi build with the dynamic virtual filesystem Lua API (PR
  [sxyazi/yazi#4338](https://github.com/sxyazi/yazi/pull/4338)).
- `curl` available on `PATH`.

## Installation

Via the Yazi package manager, from this repository:

```sh
ya pkg add partrita/yazi:ftp
```

Or manually, copy the `ftp.yazi` directory into your plugins directory:

```sh
# Unix
cp -r ftp.yazi ~/.config/yazi/plugins/ftp.yazi
```

## Configuration

Add the scheme to `~/.config/yazi/vfs.toml` (create it if it does not exist).

Anonymous access to any host:

```toml
[ftp."*"]
kind = "mount"
run  = "ftp"
```

Authenticated access to a specific host:

```toml
[ftp.example.com]
kind     = "mount"
run      = "ftp"
user     = "alice"
password = "s3cret"
tls      = true
```

Custom port:

```toml
[ftp.example.com]
kind = "mount"
run  = "ftp"
port = 2121
```

The domain between the scheme and the path selects the service, so both of these
work with the configuration above:

```
ftp://example.com//pub/linux
ftp://ftp.gnu.org//gnu/bash
```

The second one matches the catch-all `*` entry.

> **Note**
> The port belongs in `vfs.toml`, not in the URL. Yazi treats a `:number`
> suffix in the authority as internal metadata and strips it from the domain,
> so `ftp://example.com:2121//pub` would not match `[ftp.example.com]`.

### Options

| Key        | Type    | Default              | Description                                        |
| ---------- | ------- | -------------------- | -------------------------------------------------- |
| `host`     | string  | the URL domain       | Override the host to connect to.                   |
| `port`     | integer | `21`                 | Port.                                              |
| `user`     | string  | `anonymous`          | Login user.                                        |
| `password` | string  | `anonymous@`         | Login password.                                    |
| `tls`      | boolean | `false`              | Require explicit FTPS (`AUTH TLS`).                |
| `seek`     | boolean | `false`              | Enable random access via `REST`. See notes below.  |
| `timeout`  | integer | `30`                 | Connection timeout in seconds.                     |

## Usage

Navigate to an FTP URL from within Yazi, for example with `cd`, or by typing the
URL into the path bar:

```
ftp://example.com//pub
```

## Supported operations

| Operation                 | Implementation       |
| ------------------------- | -------------------- |
| List directories          | `LIST` (`curl`)      |
| Stat / inspect            | `LIST` of the parent |
| Preview / open / download | `RETR` (`curl`)      |
| Create directory          | `MKD`                |
| Remove directory          | `RMD`                |
| Remove file               | `DELE`               |
| Rename / move             | `RNFR` + `RNTO`      |


## Notes and limitations

- **Read-only file contents.** Uploading and in-place editing (`STOR`) are not
  implemented. Copying *from* an FTP URL to a local directory works and streams
  the file over `RETR`.
- **Metadata comes from the directory listing.** FTP has no portable stat
  command, so a single path is resolved by listing its parent and matching the
  name. `MLSD` (RFC 3659) facts are used when a server returns them; otherwise
  the classic Unix `ls -l` format is parsed. Non-Unix listing formats (for
  example some Windows IIS servers) may not parse.
- **Symlinks** are shown with the target reported by the server. Following a
  directory symlink is not supported.
- **Seeking** is disabled by default for reliability: downloads and previews
  stream sequentially from the start. Set `seek = true` to enable random access
  through the `REST` command, which is faster for large media previews on
  servers that support it, but fails on servers that do not.
- **One connection per operation.** FTP has no multiplexing, so each `LIST`,
  `RETR`, or command opens a fresh login. Yazi revalidates the visible remote
  directory on a 2-second timer; the provider reports "unchanged" unless the
  parent listing changed, so the directory is not re-listed every tick, but a
  stat (`LIST` of the parent) still happens every 2 seconds while an `ftp://`
  directory is open.
