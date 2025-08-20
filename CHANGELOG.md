## next

* Allow configuring server URI instead of host and port (#4)
  * The CLI still allows to configure server/port, but allows to pass the
    URI which takes precedence
  * This is a breaking change for `Object#remote_pry` as its signature is
    changed to keyword arguments (`uri:, **options`)
  * The `PryRemoteReloaded::Server.new` and `PryRemoteReloaded::Server.run`
    signatures also changed to keyword arguments,
    but thats only for internal use

## 2.0.0 (205-08-19)

* Upgraded to slop 4.x (#3)
* Require Pry >= 0.15 (#3)

## 1.2.0 (2025-01-24)

* Added the drb dependency

## 1.1.0 (2023-12-07)

* Require Pry >= 0.14

## 1.0.0 (2017-12-13)

* Relaxed the Pry dependencies version condition (>=0.9)
* [Reuse default Pry hooks](https://github.com/Mon-Ouie/pry-remote/pull/64)
* Added improved interrupt handling (Ctrl+C results in a clean Pry exit)
* Improved general error handling
