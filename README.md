# mpv remote over IPC

A remote for [Unified Remote](https://www.unifiedremote.com/) to control [mpv](https://mpv.io/) over IPC.

**Benefits of IPC:**

* Keyboard-layout agnostic

  Keystrokes are interpreted and converted by the operating system, so only standard qwerty might work as expected.
  This remote does not use keystrokes, but crafted messages to communicate and control mpv.

* Key-binding agnostic

  Configuring mpv to use non-default key bindings might make other remotes unusable or behave strangely. This remote
  doesn't use key bindings.

* Window-focus agnostic

  Keystrokes require mpv to be the focused window by the operating system. In case it loses focus, the keystrokes will
  be sent to the wrong program, and other remotes will stop working. This remote can communicate with mpv even if mpv is
  hidden or minimized, by using the file system.

**Drawbacks of IPC:**

* ***IPC can be a security risk***

    mpv's IPC protocol by design features no authentication or encryption, and exposes mpv's ability to execute arbitrary commands. Make sure the IPC socket has appropriate permissions (i.e. readable and writeable only by the users running `mpv` and `urserver`). It is a good idea to only run `urserver` behind a firewall on a trusted network and to enable its authentication feature.

* IPC must be configured

  The IPC is not enabled by default in mpv. See usage below.


* No support for Microsoft Windows

  Although mpv supports named pipes under Windows, this remote has currently no support for using them. Add an issue or
  pull request for it.

* Controlling multiple instances of mpv is a hassle

  It is possible to start multiple mpv instances, but changing which instance the remote communicates with is a bit of
  a hassle, albeit doable.

## Usage

1. Install Unified Remote.
2. Clone this repository to the directory containing the remotes.
3. Start or restart the Unified Remote server.
4. Configure mpv to enable the IPC server.

   This can be done by either specifying `--input-ipc-server=/tmp/mpv-socket` to the
   command line when starting `mpv`, or by adding it to mpv's configuration file to have it on by default.

5. Open the remote on your other device. It should try to connect automatically when started, and when trying to send a
   command.
