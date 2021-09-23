#!/usr/bin/tclsh
#
# Run this script to generate the "shell.c" source file from its
# constituent parts located normally within the SQLite source.
#
# No arguments are required.  This script determines the location
# of its input files relative to the location of the script itself.
# This script is assumed to be in <project root>/tool/mkshellc.tcl.
# By default, shell.c's constituent parts, named in INCLUDE macros,
# are located in <project root>/src and <project root>/ext/misc .
# By default, the input src/shell.c.in is read and processed.
#
# To see other execution options, run this with a --help option.
# This script may also be used for shell extensions, as described
# at https://sqlite.org/shell_extend.html . ToDo
#########1#########2#########3#########4#########5#########6#########7#########8

set ::help {
 mkshellc.tcl <options>
  <options> may be either --help, --details, --parameters or any sequence of:
    <input_filename>
    -ignored <signed_command_list>
    -inc-type <inc_type>=<include_filename>
    -source-tags <tags_degree>
    -top-dir <project_root>
    -tcl
 If no input files are specified, <PROJECT_ROOT>/src/shell.c.in is read.
 Input files are read and processed in order, producing output to sdout.

 The -ignored option affects a list of commands which, during processing,
 will be ignored and generate no output. The list starts empty.

 The -inc-type option associates a filename with an <inc_type> word which
 may be used during execution of INCLUDE(...) directives in the input.

 The -source-tags option sets the degree of #line directive emission via
 the <tags_degree> value. 0 turns tagging off. 1, which is the default,
 yields tagging only on non-macro code as it is scanned. 2 adds much more
 tagging, (about 3x), on individual dispatch and help table entries, and
 on conditional compilation preprocessor directives.

 Input files may include macro lines or line sequences matching any of:
  INCUDE <file_name>\
}
# MACRO_DOSTUFF ...
set ::helpMore {
 Use --details option for detailed effects of these macros.
 Use --parameters option for CONFIGURE_DISPATCH parameter names and effects.
}

set ::headComment {/* DO NOT EDIT!
** This file is automatically generated by the script in the canonical
** SQLite source tree at tool/mkshellc.tcl.  That script combines and
** transforms code from various constituent source files of SQLite into
** this single "shell.c" file to implement the SQLite command-line shell.
**
** Most of the code found below comes from the "src/shell.c.in" file in
** the canonical SQLite source tree.  That main file contains "INCLUDE"
** lines that specify other files in the canonical source tree that are
** inserted and transformed, (via macro invocations explained by running
** "tool/mkshellc.tcl --help"), to generate this complete program source.
**
** By means of this generation process, creating this single "shell.c"
** file, building the command-line program is made simpler and easier.
**
** To modify this program, get a copy of the canonical SQLite source tree,
** edit file src/shell.c.in and/or some of the other files included by it,
** then rerun the tool/mkshellc.tcl script.
*/}

set ::headCommentLines [expr 1+[regexp -all "\n" $::headComment]]

set ::topdir [file dir [file dir [file normal $argv0]]]
set runMode normal
set ::lineDirectives 1
set ::tclGenerate 0
set ::verbosity 0
set infiles {}
array set ::incTypes [list "*" "$::topdir/src/shell.c.in"]
array set ::ignoringCommands [list]

while  {[llength $argv] > 0} {
  set argv [lassign $argv opt]
  if {[regexp {^-{1,2}((help)|(details)|(parameters))$} $opt ma ho]} {
    set runMode $ho
  } elseif {[regexp {^-it$} $opt]} {
    set argv [lassign $argv nextOpt]
    if {![regexp {^(\w+)=(.+)$} $nextOpt ma k v]} {
      puts stderr "Get help with --help."
      exit 1 
    }
    set ::incTypes($k) $v
  } elseif {$opt eq "-top-dir"} {
    set argv [lassign $argv ::topdir]
    if {::topdir eq ""} { set ::topdir . }
  } elseif {$opt eq "-source-tags"} {
    set argv [lassign $argv nextOpt]
    if {![regexp {^\d$} $nextOpt ::lineDirectives]} {
      puts stderr "Argument following -source-tags must be a digit."
    }
  } elseif {$opt eq "-tcl"} {
    puts stderr "Warning: Tcl extension not wholly implemented."
    set ::tclGenerate 1
  } elseif {$opt eq "-v"} {
    incr ::verbosity
  } elseif {[regexp {^[^-]} $opt]} {
    lappend infiles $opt
  } else {
    puts stderr "Skipping unknown option: $opt"
  }
}
if {$runMode eq "normal"} {
  if {[llength $infiles] == 0} {
    lappend infiles $::incTypes(*)
  }
  fconfigure stdout -translation {auto lf}
  set out stdout
}
fconfigure $in -translation auto

if {$::lineDirectives >= 2} {
  # These k/v stores hold {filename lineNum} lists keyed by meta-command,
  # used to get #line directives on all dispatch and help table entries,
  # and any conditionals affecting their compilation.
  array set ::cmd_help_tags {}
  array set ::cmd_dispatch_tags {}
  array set ::cmd_conditional_tags {}
}
proc lineDirective {filename lineNum} {return "#line $lineNum \"${filename}\""}

array set ::cmd_help {}
array set ::cmd_dispatch {}
array set ::cmd_condition {}
array set ::inc_type_files {}
set ::iShuffleErrors 0
regexp {(\{)(\})} "{}" ma ::lb ::rb ; # Ease use of { and } in literals.

# Setup dispatching function signature and table entry struct .
# The effect of these key/value pairs is as this --parameters output says:
set ::parametersHelp {
  The following parameters given to DISPATCH_CONFIG have these effects:
   RETURN_TYPE sets the generated dispatchable function signature return type.
   STORAGE_CLASS sets the dispatchable function linkage, (typically "static".)
   ARGS_SIGNATURE sets the formal argument list for the dispatchable functions.
   DISPATCH_ENTRY sets the text of each entry line in emitted dispatch table.
   DISPATCHEE_NAME sets the name to be generated for dispatchable functions.
   CMD_CAPTURE_RE sets a regular expression to be used for capturing the name
     to be used for meta-commands within a line passed into COLLECT_DISPATCH,
     (which is needed to permit them to be emitted in lexical order by name.)
   DC_ARG_COUNT sets the effective argument count for DISPATCHABLE_COMMAND().
   DC_ARG#_DEFAULT sets a default value, DISPATCHABLE_COMMAND() #'th argument.
   HELP_COALESCE sets whether to coalesce secondary help text and add newlines.
  Within values set for ARGS_SIGNATURE, DISPATCHEE_NAME, and DISPATCH_ENTRY
  parameters, the variables $cmd and $arg# (where # is an integer) may appear,
  to be replaced by the meta-command name or the #'th effective argument to
  DISPATCHABLE_COMMAND(). The "effective" argument is either what is provided,
  or a default value when the actual argument is missing (at the right end of
  the provided argument list) or the argument has the value ? . The expansion
  of $cmd and $arg# variables is done by Tcl evaluation (via subst), allowing
  a wide range of logic to be employed in the derivation of effective values.
}
array set ::dispCfg [list \
  RETURN_TYPE int \
  STORAGE_CLASS static \
  ARGS_SIGNATURE "char *\$arg4\\\[\\\], int \$arg5, ShellState *\$arg6" \
  DISPATCH_ENTRY \
   "{ \"\$cmd\", \${cmd}Command, \$arg1,\$arg2,\$arg3 }," \
  DISPATCHEE_NAME {${cmd}Command} \
  CMD_CAPTURE_RE "^\\s*$::lb\\s*\"(\\w+)\"" \
  HELP_COALESCE 0 \
]
# Other config keys:
#  DC_ARG_COUNT=<number of arguments to DISPATCHABLE_COMMAND()>
#  DC_ARG#_DEFAULT=<default value for the #th argument>
# Variables $cmd and $arg# (where # = 0 .. DC_ARG_COUNT-1) have values
# when ARGS_SIGNATURE, DISPATCH_ENTRY, and DISPATCHEE_NAME are evaluated.

proc condition_command {cmd pp_expr} {
  if {[regexp {^(!)?defined\(\s*(\w+)\s*\)} $pp_expr ma bang pp_var]} {
    if {$bang eq "!"} {
      set pp_expr "#ifndef $pp_var"
    } else {
      set pp_expr "#ifdef $pp_var"
    }
  } else {
    set pp_expr "#if [string trim $pp_expr]"
  }
  set ::cmd_condition($cmd) $pp_expr
}

proc emit_conditionally {cmd lines ostrm {indent ""} {cmdTagStore {}}} {
  set wrapped [info exists ::cmd_condition($cmd)]
  set iPut 0
  if {$wrapped} {
    if {$::lineDirectives >= 2} {
      puts $ostrm [lineDirective $::cmd_conditional_tags($cmd)]
      incr iPut
    }
    puts $ostrm $::cmd_condition($cmd)
    incr iPut
  }
  if {$::lineDirectives >= 2} {

    set fnln subst[[subst "\$$cmdTagStore(\$cmd)"]]
    puts $ostrm [lineDirective {*}$fnln]
    incr iPut
  }
  if {[regexp {^\s*(\d+)\s*$} $indent ma inum]} {
    set lead [string repeat " " $inum]
    foreach line $lines {
      puts $ostrm "$lead[string trimleft $line]"
    }
  } else {
    puts $ostrm [join $lines "\n"]
  }
  incr iPut [llength $lines]
  if {$wrapped} {
    puts $ostrm "#endif"
    incr iPut
  }
  return $iPut
}

# Coalesce secondary help text lines using C's string literal concatenation
# and arrange that each command's help has one primary (leading '.') help
# text line and one secondary help text line-set even if it is empty.
proc coalesce_help {htin} {
  set htrv {}
  foreach hl $htin {
    if {[regexp {^\s*"\.\w+} $hl]} { ;# "
      lappend htrv [regsub {"\s*,\s*$} $hl {\n",}]
    } elseif {[regexp {^\s*#\s*\w+} $hl]} {
      lappend htrv $hl
    } else {
      lappend htrv [regsub {"\s*,\s*$} $hl {\n"}]
    }
  }
  lappend htrv {"",}
}

# Convert list of help text lines into a key-value list.
# Keys are the command names. Values are the help for the
# commands as a list of lines, with .* logically first.
# Any #if... #endif structures are maintained and do not
# interact with "logically first" .* lines, except that
# only one such line is seen within such a conditional.
# (The effect of this is to defeat sorting by command if
# help for multiple commands' is within one conditional.)
proc chunkify_help {htin} {
  array set rv [list]
  set if_depth 0
  set cmd_seen ""
  set chunk {}
  foreach htx $htin {
    if {[regexp {^\s*\"\.\w} $htx] && $cmd_seen ne "" && $if_depth == 0} {
      # Flush accumulated chunk.
      set rv($cmd_seen) $chunk
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
      set rv($cmd_seen) $chunk
    } elseif {$cmd_seen ne "" || [llength $chunk] > 0} {
      puts stderr "Orphaned help: '$cmd_seen' [join $chunk \n]"
      incr ::iShuffleErrors
    }
  }
  if {$::dispCfg(HELP_COALESCE)} {
    foreach cmd_seen [array names rv] {
      set rv($cmd_seen) [coalesce_help $rv($cmd_seen)]
    }
  }
  return [array get rv]
}

array set ::macroTailREs [list \
  COLLECT_DISPATCH {^\(\s*([\w\*]+)\s*\)\[} \
  COLLECT_HELP_TEXT {^\[} \
  COMMENT {\s+(.*)$} \
  CONDITION_COMMAND {^\(\s*(\w+)\s+([^;]+)\);} \
  DISPATCH_CONFIG {^\[} \
  DISPATCHABLE_COMMAND {^\(([\w\? ]+)\)(\S)\s*$} \
  EMIT_DISPATCH {^\((\d*)\)} \
  EMIT_HELP_TEXT {^\((\d*)\)} \
  INCLUDE {^(?:\(\s*(\w+)\s*\))|(?:\s+([\w./\\]+)\M)} \
  IGNORE_COMMANDS {^\(\s*([-+\w ]*)\)\s*;\s*} \
]
# Names of the subcaptures as formal parameter to macro procs.
# COMMENT tailCapture_Commentary
# CONDITION_COMMAND tailCapture_Cmd_Condition
# CONFIGURE_DISPATCH tailCapture_Empty
# COLLECT_DISPATCH tailCapture_Cmd
# COLLECT_HELP_TEXT tailCapture_Empty
# DISPATCHABLE_COMMAND tailCapture_ArgsGlom_TrailChar
# EMIT_DISPATCH tailCapture_Indent
# EMIT_HELP_TEXT tailCapture_Indent
# IGNORED_COMMANDS tailCapture_SignedCmdGlom
# INCLUDE tailCapture_IncType_Filename

array set ::macroUsages [list \
  COLLECT_DISPATCH "\[\n   <dispatch table entry lines>\n  \];" \
  COLLECT_HELP_TEXT "\[\n   <help text lines>\n  \];" \
  COMMENT " <arbitrary characters to end of line>" \
  CONDITION_COMMAND "( name pp_expr );" \
  DISPATCH_CONFIG "\[\n   <NAME=value lines>\n  \];" \
  DISPATCHABLE_COMMAND \
      "( name args... ){\n   <implementation code lines>\n  }" \
  EMIT_DISPATCH "( indent );" \
  EMIT_HELP_TEXT "( indent );" \
  INCLUDE {( <inc_type> )} \
  SKIP_COMMANDS "( <signed_names> );" \
]
# RE for early discard of non-macro lines, matching all above keywords
set ::macroKeywordTailRE \
 {^\s{0,8}((?:(?:CO)|(?:DI)|(?:EM)|(?:IN)|(?:SK))[A-Z_]+)\M(.+)$}

# RE to recognize macros which may emit and probably will.
set ::emitterMacrosRE {^[DEI]}
# RE to recognize macros which certainly will not emit.
set ::consumerMacrosRE {^[CS]}
# RE to recognize macros which have gather/scatter operation, and will emit.
set ::shufflerMacrosRE {^E}
# Above 3 RE's are used to trigger needed #line emits and avoid useless ones.

set ::splat15 [string repeat * 15]
set ::sharp15 "//[string repeat # 13]"

# Put marker and possibly a #line directive signifying end of an inclusion.
# Return number of lines emitted.
proc includeEnd {fromFile returnFile lineNum ostrm} {
  if {$returnFile eq ""} {
  } else {
    set rsay ", resume $returnFile"
  }
  if {$::tclGenerate} {
    puts $ostrm "$::sharp15 End $fromFile$rsay $::sharp15"
  } else {
    puts $ostrm "/$::splat15 End $fromFile$rsay ${::splat15}/"
  }
  # Skip #line directives if not doing them, at end of outer includer,
  # or processing Tcl. (At end of outer includer, #line is pointless.)
  if {$::lineDirectives && !$::tclGenerate && $returnFile ne ""} {
    puts $ostrm "#line $lineNum \"${returnFile}\""
    return 2
  }
  return 1
}
# Possibly put a #line directive within the middle of an includee's output,
# whether during input scan or upon deferred output.
# Return number of lines emitted.
proc includeMiddle {withinFile lineNum ostrm} {
  if {$::lineDirectives && !$::tclGenerate} {
    puts "#line $lineNum \"${withinFile}\""
    return 1
  }
  return 0
}
# Put marker and possibly a #line directive signifying top of an inclusion.
# Return number of lines emitted.
proc includeBegin {startFile ostrm} {
  if {$::tclGenerate} {
    puts $ostrm "$::sharp25 Begin $startFile $::sharp25"
  } else {
    puts $ostrm "/$::splat25 Begin $startFile ${::splat25}/"
  }
  if {$::lineDirectives && !$::tclGenerate} {
    puts $ostrm "#line 1 \"${startFile}\""
    return 2
  }
  return 1
}

proc IGNORED_COMMANDS {inSrc tcSignedCmdGlom ostrm} {
  # Cause the listed commands to be ignored or allowed to generate, as set
  # by a preceeding + or - respectively in the list. This may be useful
  # when statically extending the shell to avoid duplicate implementation.
  # Commands never mentioned within this macro are allowed to generate.
  set sign ""
  foreach {. o} [regexp -inline -all {\s*([\-\+]|[\w]+)\s*} $tcSignedCmdGlom] {
    if {![regexp {[\+\-\?]} $o . sign]} {
      if {$sign eq "+"} {
      } else {
      }
    }
  }
  return [list 0 0]
  
}

proc COLLECT_DISPATCH {inSrc tailCaptureCmdOrStar ostrm} {
  # Collect dispatch table entries, along with cmd(s) as ordering info.
  foreach {infile istrm inLineNum} $inSrc {}
  foreach {cmd} $tailCaptureCmdOrStar {}
  set iAte 0
  set lx [gets $istrm]
  set disp_frag {}
  while {![eof $istrm] && ![regexp {^\s*\];} $lx]} {
    lappend disp_frag $lx
    set grabCmd $::dispCfg(CMD_CAPTURE_RE)
    if {![regexp $grabCmd $lx ma dcmd]} {
      puts stderr "malformed dispatch element:\n $lx"
      incr ::iShuffleErrors
    } elseif {$cmd ne "*" && $dcmd ne $cmd} {
      puts stderr "misdeclared dispatch element:\n $lx"
      incr ::iShuffleErrors
    } else {
      set ::cmd_dispatch($dcmd) [list $lx]
    }
    set lx [gets $istrm]
    incr iAte
  }
  incr iAte
  return [list $iAte 0]
}

proc COMMENT {hFile tailCaptureIgnore ostrm} {
  # Allow comments in an input file which have no effect on output.
  return 1
}

proc INCLUDE {hFile tailCaptureIncType ostrm} {
  # If invoked with a bare filename, include the named file. If invoked
  # with the parenthesized word form, include a file named by means of
  # the '-it <inc_type>=filename' command line option, provided that the
  # word matches a specified <inc_type>. Otherwise, do nothing.
  set it [lindex $tailCaptureIncType 0]
  if {[regexp {\s*([a-zA-Z\._\\/]+)\s*} $it ma it]} {
    if {[info exists ::incTypes($it)]} {
      set fname $::incTypes($it)
      puts $ostrm "/* INCLUDE($it), of \"$fname\" skipped. */"
      # ToDo: Get including done with a proc so it can be done from here.
      # This will support emitting #line directives to aid debugging.
    }
  }
  return 1
}

proc COLLECT_HELP_TEXT {hFile tailCaptureEmpty ostrm} {
  # Collect help text table values, along with ordering info.
  set iAte 0
  set help_frag {}
  set lx [gets $hFile]
  while {![eof $hFile] && ![regexp {^\s*\];} $lx]} {
    lappend help_frag $lx
    set lx [gets $hFile]
    incr iAte
  }
  incr iAte
  array set ::cmd_help [chunkify_help $help_frag]
  return $iAte
}

proc CONDITION_COMMAND {hFile tailCap ostrm} {
  # Name a command to be conditionally available, with the condition.
  condition_command [lindex $tailCap 0] [string trim [lindex $tailCap 1]]
  return 0
}

proc DISPATCH_CONFIG {hFile tailCaptureEmpty ostrm} {
  # Set parameters affecting generated dispatchable command function
  # signatures and generated dispatch table entries.
  set iAte 0
  set def_disp {}
  set lx [gets $hFile]
  while {![eof $hFile] && ![regexp {^\s*\];} $lx]} {
    lappend def_disp $lx
    set lx [gets $hFile]
    incr iAte
  }
  incr iAte
  foreach line $def_disp {
    if {[regexp {^\s*(\w+)=(.+)$} $line ma k v]} {
      set ::dispCfg($k) $v
    }
  }
  return $iAte
}

proc DISPATCHABLE_COMMAND {hFile tailCapture ostrm} {
  # Generate and emit a function definition, maybe wrapped as set by
  # CONDITION_COMMAND(), and generate/collect its dispatch table entry,
  # as determined by its actual arguments and DISPATCH_CONFIG parameters.
  set args [lindex $tailCapture 0]
  set tc [lindex $tailCapture 1]
  if {$tc ne $::lb} {
    yap_usage "DISPATCHABLE_COMMAND($args)$tc" DISPATCHABLE_COMMAND
    incr $::iShuffleErrors
    return 0
  }
  set iAte 0
  set args [split [regsub {\s+} [string trim $args] " "]]
  incr iAte
  set na [llength $args]
  set cmd [lindex $args 0]
  set naPass $::dispCfg(DC_ARG_COUNT)
  if {$na > $naPass} {
    puts stderr "Bad args: $lx"
  } else {
    while {$na < $naPass} {
      set nad "DC_ARG${na}_DEFAULT"
      if {![info exists ::dispCfg($nad)]} {
        puts stderr "Too few args: $lx (need $naPass)"
        incr ::iShuffleErrors
        break
      } else {
        lappend args [subst $::dispCfg($nad)]
      }
      incr na
    }
    set body {}
    while {![eof $hFile]} {
      set bl [gets $hFile]
      incr iAte
      lappend body $bl
      if {[regexp "^$::rb\\s*\$" $bl]} { break }
    }
    for {set aix 1} {$aix < $na} {incr aix} {
      set av [lindex $args $aix]
      if {$av eq "?"} {
        set ai [expr {$aix + 1}]
        set aid "DC_ARG${ai}_DEFAULT"
        set av [subst $::dispCfg($aid)]
      }
      set "arg$aix" $av
    }
    if {$cmd ne "?"} {
      set rsct $::dispCfg(STORAGE_CLASS)
      set rsct "$rsct $::dispCfg(RETURN_TYPE)"
      set argexp [subst $::dispCfg(ARGS_SIGNATURE)]
      set fname [subst $::dispCfg(DISPATCHEE_NAME)]
      set funcOpen "$rsct $fname\($argexp\)$::lb"
      set dispEntry [subst $::dispCfg(DISPATCH_ENTRY)]
      emit_conditionally $cmd [linsert $body 0 $funcOpen] $ostrm
      set ::cmd_dispatch($cmd) [list $dispEntry]
    }
  }
  return $iAte
}

proc EMIT_DISPATCH {hFile tailCap ostrm} {
  # Emit the collected dispatch table entries, in command order, maybe
  # wrapped with a conditional construct as set by CONDITION_COMMAND().
  foreach cmd [lsort [array names ::cmd_dispatch]] {
    emit_conditionally $cmd $::cmd_dispatch($cmd) $ostrm $tailCap
  }
  return 0
}

proc EMIT_HELP_TEXT {hFile tailCap ostrm} {
  # Emit the collected help text table entries, in command order, maybe
  # wrapped with a conditional construct as set by CONDITION_COMMAND().
  foreach htc [lsort [array names ::cmd_help]] {
    emit_conditionally $htc $::cmd_help($htc) $ostrm $tailCap
  }
  return 0
}

proc say_usage {macros {extra {}}} {
  puts stderr "Usage:$extra"
  foreach m $macros {puts stderr "  $m$::macroUsages($m)"}
}
proc yap_usage {got macro} {
  puts stderr "Bad macro use: $got"
  say_usage $macro
}

# Perform any input collection or deferred output emits.
# This function may consume additional lines via hFile.
# Return number of lines absorbed. A 0 return means the
# input line lx had no meaning to the shuffle processing,
# in which case it is emitted as-is.
proc do_shuffle {hFile lx ostrm} {
  set iAte 0
  if {![regexp $::macroKeywordTailRE $lx ma macro tail] \
          || ![info exists ::macroTailREs($macro)]} {
    puts $ostrm $lx
  } else {
    # It's an attempted macro invocation line. Process or fail and yap.
    incr iAte ; # Eat the macro and whatever it swallows (if invoked).
    set tailCap [regexp -inline $::macroTailREs($macro) $tail]
    if {[llength $tailCap]>0} {
      # Call like-named proc with any args captured by the corresponding RE.
      incr iAte [$macro $hFile [lrange $tailCap 1 end] $ostrm]
    } else {
      # ToDo: complain
      incr $::iShuffleErrors
    }
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
  if {[regexp {^#include "sqlite.*"} $line]} {
    return "/* $line */"
  }
  if {[regexp {^# *include "test_windirent.h"} $line]} {
    return "/* $line */"
  }
  return [string map [list __declspec(dllexport) {}] $line]
}

if {$customRun == 2} {
  # Show options and usage
  say_usage [lsort [array names ::macroUsages]] {
 mkshellc.tcl <options>
  <options> may be either --help, --details, --parameters or any sequence of:
    <input_filename>
    -it <inc_type>=<include_filename>
    -tcl
    -no-line-directives
 If no input files are specified, <PROJECT_ROOT>/src/shell.c.in is read.
 Input files are read and processed in order, producing output to sdout.
 The -it option associates a filename with an <inc_type> word which may
 be encountered during execution of INCLUDE(...) directives in the input.
 Input files may include macro lines or line sequences matching any of:
  INCUDE <file_name> }
  puts stderr {
 Use --details option for detailed effects of these macros.
 Use --parameters option for DISPATCH_CONFIG parameter names and effects.
  }
  exit 0
} elseif {$customRun == 3} {
  set sfd [open $argv0 r]
  array set macdos [list]
  while {![eof $sfd]} {
    if {[regexp {^proc ([A-Z_]+\M)} [gets $sfd] ma macro]} {
      if {[info exists ::macroTailREs($macro)]} {
        set effects {}
        while {[regexp {^\s+#\s*(.+)$} [gets $sfd] ma effect]} {
          lappend effects " $effect"
        }
        set macdos($macro) [join $effects "\n"]
      }
    }
  }
  close $sfd
  foreach m [lsort [array names macdos]] {
    puts stderr "\nThe $m macro will:\n $macdos($m)"
  }
  exit 0
} elseif {$customRun == 4} {
  puts stderr $::parametersHelp
  exit 0
}

fconfigure stdout -translation {auto lf}
if {$customRun == 0} {
  puts $out $headComment
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
    set in2 [open $topdir/src/$cfile r]
    fconfigure $in2 -translation auto
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
if {$customRun < 2} {
  close $in
}
close $out

exit $::iShuffleErrors
