<img align="right" width="200" src="logo.png"/>

GRASShopper
=======
![Version 0.4 alpha](https://img.shields.io/badge/version-0.4_alpha-green.svg)
[![BSD licensed](https://img.shields.io/badge/license-BSD-blue.svg)](https://raw.githubusercontent.com/wies/grasshopper/master/LICENSE)
[![Build Status](https://travis-ci.org/wies/grasshopper.svg?branch=master)](https://travis-ci.org/wies/grasshopper)

GRASShopper is an experimental verification tool for programs that
manipulate dynamically allocated data structures. GRASShopper programs
can be annotated with specifications expressed in a decidable
specification logic to check functional correctness properties. The
logic supports mixing of separation logic and first-order logic
assertions, yielding expressive yet concise specifications.

The tool is released under a BSD license, see file LICENSE for
details.


Installation Requirements
-------------------------
- OCaml, version >= 4.01

- Z3, version >= 3.2, and/or

- CVC4, version >= 1.5

GRASShopper has been tested on Linux, Mac OS, and Windows/Cygwin.


Installation Instructions 
-------------------------
- To produce native code compiled executables, run 
```bash
./build.sh
```

- Optional: to check whether the build succeeded, run
```bash
./build.sh tests
```

Usage
-------------------------

To run GRASShopper, execute e.g.
```bash
./grasshopper.native tests/spl/sl/sl_reverse.spl
```
The analyzer expects the Z3 (respectively, CVC4) executable in the path.

To see the available command line options, run
```bash
./grasshopper.native -help
```

Emacs Modes
-------------------------
GRASShopper provides two emacs modes for GRASShopper programs:

- SPL mode: this mode provides syntax highlighting and automatic
  indentation for the GRASShopper input programs (see tests/spl for
  examples).

- GHP mode: this mode provides syntax highlighting for the intermediate 
  representation of programs inside GRASShopper. Such programs can be
  generated by running GRASShopper with the option `-dumpghp n`.
  Here, n=0,1,2,3 refers to the n-th simplification stage of
  verification condition generation.

To use the emacs modes, copy the files in the directory emacs-mode to
your site-lisp directory and add the following lines to your `.emacs` file:

```elisp
(load "spl-mode")   
(load "ghp-mode")
```

Optional: Flycheck minor mode

If you are using Emacs 24.1 or newer, we suggest to use the
flycheck minor mode of the SPL emacs mode. To do so, copy the file
emacs-mode/flycheck.el into your `site-lisp` directory. Additionally,
you need to put the GRASShopper executable in your path and rename it
to `grasshopper`. The mode supports on-the-fly syntax and type
checking of SPL programs and provides keyboard shortcuts for verifying
the program from inside buffers. See the documentation in the file
`spl-mode.el` for details.

Note that we are using a patched version of the original flycheck mode
by Sebastian Wiesner. The minor mode will not work correctly with the
original version of the flycheck mode.

For more information visit http://cs.nyu.edu/wies/software/grasshopper
