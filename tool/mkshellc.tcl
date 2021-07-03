#!/usr/bin/tclsh
#
# Run this script to generate the "shell.c" source file from 
# constituent parts.
#
# No arguments are required.  This script determines the location
# of its input files relative to the location of the script itself.
# This script should be tool/mkshellc.tcl.  If the directory holding
# the script is $DIR, then the component parts are located in $DIR/../src
# and $DIR/../ext/misc.
#
set topdir [file dir [file dir [file normal $argv0]]]
set out stdout
fconfigure stdout -translation {auto lf}
puts $out {/* DO NOT EDIT!
** This file is automatically generated by the script in the canonical
** SQLite source tree at tool/mkshellc.tcl.  That script combines source
** code from various constituent source files of SQLite into this single
** "shell.c" file used to implement the SQLite command-line shell.
**
** Most of the code found below comes from the "src/shell.c.in" file in
** the canonical SQLite source tree.  That main file contains "INCLUDE"
** lines that specify other files in the canonical source tree that are
** inserted to getnerate this complete program source file.
**
** The code from multiple files is combined into this single "shell.c"
** source file to help make the command-line program easier to compile.
**
** To modify this program, get a copy of the canonical SQLite source tree,
** edit the src/shell.c.in" and/or some of the other files that are included
** by "src/shell.c.in", then rerun the tool/mkshellc.tcl script.
*/}

set in [open $topdir/src/shell.c.in rb]

proc omit_redundant_typedefs {line} {
}

set ::cmd_help [dict create]
set ::cmd_dispatch [dict create]
set ::iShuffleErrors 0

# Convert list of help text lines into a dict.
# Keys are the command names. Values are the help for the
# commands as a list of lines, with .* logically first.
# Any #if... #endif structures are maintained and do not
# interact with "logically first" .* lines, except that
# only one such line is seen within such a conditional.
# (The effect of this is to defeat sorting by command if
# help for multiple commands' is within one conditional.)
proc chunkify_help {htin} {
  set rv [dict create]
  set if_depth 0
  set cmd_seen ""
  set chunk {}
  foreach htx $htin {
    if {[regexp {^\s*\"\.\w} $htx] && $cmd_seen ne "" && $if_depth == 0} {
      # Flush accumulated chunk.
      dict set rv $cmd_seen $chunk
      set cmd_seen ""
      set chunk {}
    }
    lappend chunk $htx
    if {[regexp {^\s*#if} $htx]} {
      incr if_depth
    } elseif {[regexp {^\s*#endif} $htx]} {
      incr if_depth -1
    } else {
      if {[regexp {^\s*\"\.(\w+)} $htx all cmd] && $cmd_seen eq ""} {
        set cmd_seen $cmd
      }
    }
  }
  if {$if_depth != 0} {
    puts stderr "Help chunk bad #conditional:"
    puts stderr [join $htin "\n"]
    puts stderr "Swallowed [join $chunk \n]"
    incr ::iShuffleErrors
  } else {
    if {$cmd_seen ne "" && [llength $chunk] > 0} {
      # Flush accumulated chunk.
      dict set rv $cmd_seen $chunk
    } elseif {$cmd_seen ne "" || [llength $chunk] > 0} {
      puts stderr "Orphaned help: '$cmd_seen' [join $chunk \n]"
      incr ::iShuffleErrors
    }
  }
  return $rv
}

# Perform any input collection or deferred output emits.
# This function may consume additional lines via hFile.
# Return number of lines absorbed. A 0 return means the
# input line lx had no meaning to the shuffle processing,
# in which case it is emitted as-is.
proc do_shuffle {hFile lx ostrm} {
  set iAte 0
  if {[regexp {^COLLECT_HELP_TEXT\[} $lx]} {
    incr iAte
    set help_frag {}
    set lx [gets $hFile]
    while {![eof $hFile] && ![regexp {^\s*\];} $lx]} {
      lappend help_frag $lx
      set lx [gets $hFile]
      incr iAte
    }
    incr iAte
    set ::cmd_help [dict merge $::cmd_help [chunkify_help $help_frag]]
  } elseif {[regexp {^\s*EMIT_HELP_TEXT\(\)} $lx]} {
    incr iAte
    foreach htc [lsort [dict keys $::cmd_help]] {
      puts $ostrm [join [dict get $::cmd_help $htc] "\n"]
    }
  } elseif {[regexp {^COLLECT_DISPATCH\(\s*(\w+)\s*\)\[} $lx ma cmd]} {
    incr iAte
    set disp_frag {}
    set lx [gets $hFile]
    while {![eof $hFile] && ![regexp {^\s*\];} $lx]} {
      lappend disp_frag $lx
      set lx [gets $hFile]
      incr iAte
    }
    incr iAte
    dict set ::cmd_dispatch $cmd $disp_frag
  } elseif {[regexp {^\s*EMIT_DISPATCH\(\)} $lx]} {
    incr iAte
    foreach cmd [lsort [dict keys $::cmd_dispatch]] {
      puts $ostrm [join [dict get $::cmd_dispatch $cmd] "\n"]
    }
  } else {
    puts $ostrm $lx
  }
  return $iAte
}

# Filter redundant typedefs and certain includes and qualifiers.
proc transform_line {line nesting} {
  global typedef_seen
  if {[regexp {^typedef .*;} $line]} {
    if {[info exists typedef_seen($line)]} {
      return "/* $line */"
    }
    set typedef_seen($line) 1
    return $line
  } elseif {$nesting == 0} {
    return $line
  }
  if {[regexp {^#include "sqlite} $line]} {
    return "/* $line */"
  }
  if {[regexp {^# *include "test_windirent.h"} $line]} {
    return "/* $line */"
  }
  return [string map [list __declspec(dllexport) {}] $line]
}

set iLine 0
while {1} {
  set lx [transform_line [gets $in] 0]
  if {[eof $in]} break;
  incr iLine
  if {[regexp {^INCLUDE } $lx]} {
    set cfile [lindex $lx 1]
    puts $out "/************************* Begin $cfile ******************/"
#   puts $out "#line 1 \"$cfile\""
    set in2 [open $topdir/src/$cfile rb]
    while {![eof $in2]} {
      set lx [transform_line [gets $in2] 1]
      do_shuffle $in2 $lx $out
    }
    close $in2
    puts $out "/************************* End $cfile ********************/"
#   puts $out "#line [expr $iLine+1] \"shell.c.in\""
    continue
  }
  set iAte [do_shuffle $in $lx $out]
  if {$iAte > 0} {
    incr iLine [expr {$iAte - 1}]
  }

}
close $in
close $out
exit $::iShuffleErrors
