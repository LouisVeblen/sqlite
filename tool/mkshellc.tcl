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
 yields tagging only on source file switching. 2 also produces tagging in
 places where intra-source line tracking would become invalid otherwise.
 3 yields much more tagging, (about 3x), on individual dispatch and help
 table entries, and on conditional compilation preprocessor directives.

 Input files may include macro lines or line sequences matching any of:
  INCUDE <file_name>\
}

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

set ::topDir [file dir [file dir [file normal $argv0]]]
set runMode normal

set ::lineTags 0 ; # 0 => none, 1 => source change, 2 => line syncs, 3 => more

set ::tclGenerate 0
set ::verbosity 0
set ::inFiles {}
array set ::incTypes [list "*" "$::topDir/src/shell.c.in"]
array set ::ignoringCommands [list]

while  {[llength $argv] > 0} {
  foreach {opt} $arv { set argv [lreplace $argv 1 end] ; break }
  if {[regexp {^-{1,2}((help)|(details)|(parameters))$} $opt ma ho]} {
    set runMode $ho
  } elseif {[regexp {^-it$} $opt]} {
    foreach {nextOpt} $arv { set argv [lreplace $argv 1 end] ; break }
    if {![regexp {^(\w+)=(.+)$} $nextOpt ma k v]} {
      puts stderr "Get help with --help."
      exit 1 
    }
    set ::incTypes($k) $v
  } elseif {$opt eq "-top-dir"} {
    foreach {::topDir} $arv { set argv [lreplace $argv 1 end] ; break }
    if {::topDir eq ""} { set ::topDir . }
  } elseif {$opt eq "-source-tags"} {
    foreach {nextOpt} $arv { set argv [lreplace $argv 1 end] ; break }
    if {![regexp {^\d$} $nextOpt ::lineTags]} {
      puts stderr "Argument following -source-tags must be a digit."
    }
  } elseif {$opt eq "-tcl"} {
    puts stderr "Warning: Tcl extension not wholly implemented."
    set ::tclGenerate 1
  } elseif {$opt eq "-v"} {
    incr ::verbosity
  } elseif {[regexp {^[^-]} $opt]} {
    lappend ::inFiles $opt
  } else {
    puts stderr "Skipping unknown option: $opt"
  }
}
if {$runMode eq "normal"} {
  if {[llength $::inFiles] == 0} {
    lappend ::inFiles $::incTypes(*)
  }
  fconfigure stdout -translation {auto lf}
  set ::outStrm stdout
}

# Given a path relative to <project>/src, return its full pathname.
proc project_path {relPath} {
  return "$::topDir/src/$relPath"
}

if {$::lineTags >= 3} {
  # These k/v stores hold {lineNum filename} lists keyed by meta-command,
  # which are used to get #line directives on all dispatch and help table
  # entries, and any conditionals affecting their compilation.
  array set ::cmd_help_tags {}
  array set ::cmd_dispatch_tags {}
  array set ::cmd_conditional_tags {}
}

# Set one of above k/v stores, (help, dispatch, conditional) for given
# cmd from members of inSrc triple {filename istrm lineNumber}.
proc set_src_tags {which cmd inSrc} {
  if {$::lineTags >= 3} {
    foreach {filename _ lineNumber} $inSrc break
    set [subst ::cmd_${which}_tags]($cmd) [list $lineNumber $filename]
  }
}
# Return pair {lineNumber fileName} from one of above k/v stores,
# (help, dispatch, conditional) for given cmd, or get empty list.
# The empty list indicates either not keeping such k/v, or there
# is not one for the given cmd
proc get_src_tags {which cmd} {
  if {$::lineTags >= 3 && [info exists [subst ::cmd_${which}_tags]($cmd)]} {
    return [subst "\$[subst ::cmd_${which}_tags]($cmd)"]
  }
  return {}
}

# To faciliate non-excessive line tagging, track these values before emits:
# These 2 variables are set/used only by procs line_tag and emit_sync .
set ::apparentSrcFile ""
set ::apparentSrcPrecLines $::headCommentLines

# Maybe put a #line directive if ::lineTags not 0. Directive style depends
# on its value and whether srcFile input is provided as follows:
# 1 => just file changes, 2 => line syncs too if srcFile not empty.
# A #line directive is only emitted if its kind is enabled
# All #line emits pass through this proc.
proc line_tag { ostrm srcPrecLines {srcFile ""} } {
  if {$::lineTags == 0} return
  set sayLine [expr {$srcPrecLines + 1}]
  if {$srcFile ne ""} {
    set ::apparentSrcFile $srcFile
    puts $ostrm "#line $sayLine \"$::apparentSrcFile\""
  } elseif {$::lineTags > 1} {
    puts $ostrm "#line $sayLine"
  }
  set ::apparentSrcPrecLines $srcPrecLines
}

# Put a #line directive only if needed to resynchronize compiler's
# notion of source line location with actual source line location.
# And do this only if about to emit some line(s). Then emit them.
# This proc is used for all output emits (to make this work.)
# The precLines input is the number of source lines preceding the
# one to be represented (via #line ...) as producing next output.
proc emit_sync { lines ostrm precLines {fromFile ""} } {
  if {$::lineTags > 0} {
    if {$fromFile ne "" && $fromFile ne $::apparentSrcFile} {
      line_tag $ostrm $precLines $fromFile
    } elseif {$::lineTags > 1
              && $precLines != $::apparentSrcPrecLines
              && $lines ne {}} {
      line_tag $ostrm $precLines
    }
  }
  foreach line $lines {
    puts $ostrm $line
    incr ::apparentSrcPrecLines
  }
}

array set ::cmd_help {}
array set ::cmd_dispatch {}
array set ::cmd_condition {}
array set ::metacmd_init {}
array set ::inc_type_files {}
set ::iShuffleErrors 0
# Ease use of { and } in literals. Instead, $::lb and $::rb can be used.
regexp {(\{)(\})} "{}" ma ::lb ::rb

# Setup dispatching function signature and table entry struct .
# The effect of these key/value pairs is as this --parameters output says:
set ::parametersHelp {
  The following parameters given to DISPATCH_CONFIG have these effects:
   RETURN_TYPE sets the generated dispatchable function signature return type.
   STORAGE_CLASS sets the dispatchable function linkage, (typically "static".)
   ARGS_SIGNATURE sets the formal argument list for the dispatchable functions.
   DISPATCH_ENTRY sets the text of each entry line in emitted dispatch table.
   DISPATCHEE_NAME sets the name to be generated for dispatchable functions.
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
  HELP_COALESCE 0 \
  METACMD_INIT \
   "META_CMD_INFO( \${cmd}, \$arg1,\$arg2,\$arg3,\n <HT0>,\n <HT1> )," \
]
# Other config keys:
#  DC_ARG_COUNT=<number of arguments to DISPATCHABLE_COMMAND()>
#  DC_ARG#_DEFAULT=<default value for the #th argument>
# Variables $cmd and $arg# (where # = 0 .. DC_ARG_COUNT-1) have values
# when ARGS_SIGNATURE, DISPATCH_ENTRY, and DISPATCHEE_NAME are evaluated.

proc emit_conditionally {cmd lines inSrc ostrm {indent ""} {cmdTagStore {}}} {
  foreach {fname _ lnum} $inSrc break
  set wrapped [info exists ::cmd_condition($cmd)]
  if {$wrapped} {
    emit_sync [list $::cmd_condition($cmd)] $ostrm $lnum $fname
    incr lnum
  }
  if {[regexp {^\s*(\d+)\s*$} $indent ma inum]} {
    set lead [string repeat " " $inum]
    set ilines [list]
    foreach line $lines { lappend ilines "$lead[string trimleft $line]" }
    set lines $ilines
  }
  emit_sync $lines $ostrm $lnum $fname
  incr lnum [llength $lines]
  if {$wrapped} {
    emit_sync [list "#endif"] $ostrm $lnum $fname
    incr lnum
  }
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
  COLLECT_HELP_TEXT {^\[} \
  COMMENT {\s+(.*)$} \
  CONDITION_COMMAND {^\(\s*(\w+)\s+([^;]+)\);} \
  DISPATCH_CONFIG {^\[} \
  DISPATCHABLE_COMMAND {^\(([\w\? ]+)\)(\S)\s*$} \
  EMIT_DISPATCH {^\((\d*)\)} \
  EMIT_HELP_TEXT {^\((\d*)\)} \
  EMIT_METACMD_INIT {^\((\d*)\)} \
  INCLUDE {^(?:\(\s*(\w+)\s*\))|(?:\s+([\w./\\]+)\M)} \
  IGNORE_COMMANDS {^\(\s*([-+\w ]*)\)\s*;\s*} \
]
# Names of the subcaptures as formal parameter to macro procs.
# COMMENT tailCapture_Commentary
# CONDITION_COMMAND tailCapture_Cmd_Condition
# CONFIGURE_DISPATCH tailCapture_Empty
# COLLECT_HELP_TEXT tailCapture_Empty
# DISPATCHABLE_COMMAND tailCapture_ArgsGlom_TrailChar
# EMIT_DISPATCH tailCapture_Indent
# EMIT_HELP_TEXT tailCapture_Indent
# EMIT_METACMD_INIT tailCapture_Indent
# IGNORED_COMMANDS tailCapture_SignedCmdGlom
# INCLUDE tailCapture_IncType_Filename

array set ::macroUsages [list \
  COLLECT_HELP_TEXT "\[\n   <help text lines>\n  \];" \
  COMMENT " <arbitrary characters to end of line>" \
  CONDITION_COMMAND "( name pp_expr );" \
  DISPATCH_CONFIG "\[\n   <NAME=value lines>\n  \];" \
  DISPATCHABLE_COMMAND \
      "( name args... ){\n   <implementation code lines>\n  }" \
  EMIT_DISPATCH "( indent );" \
  EMIT_HELP_TEXT "( indent );" \
  EMIT_METACMD_INIT "( indent );" \
  INCLUDE {( <inc_type> )} \
  SKIP_COMMANDS "( <signed_names> );" \
]
# RE for early discard of non-macro lines, matching all above keywords
set ::macroKeywordTailRE \
 {^\s{0,8}((?:(?:CO)|(?:DI)|(?:EM)|(?:IN)|(?:SK))[A-Z_]+)\M(.+)$}

########
# Macro procs, general signature and usage:
# inSrc is a triple, { input_filename open_input_stream input_lines_consumed }.
# Arg 2 is the macro tail as RE-captured by one of ::macroTailREs .
# ostrm is the open output stream for all regular output.
# The number of input lines consumed, including macro invocation, is returned.
#
# These procs may consume additional input, leave side-effects, or emit
# output to ostrm (via emit_sync), as individually documented.
# Their names always exactly match the invocation identifier.

proc IGNORED_COMMANDS {inSrc tcSignedCmdGlom ostrm} {
  # Cause the listed commands to be ignored or allowed to generate, as set
  # by a preceeding + or - respectively in the list. This may be useful
  # when statically extending the shell to avoid duplicate implementation.
  # Commands never mentioned within this macro are allowed to generate.
  # TBD WIP
  set sign ""
  foreach {. o} [regexp -inline -all {\s*([\-\+]|[\w]+)\s*} $tcSignedCmdGlom] {
    if {![regexp {[\+\-\?]} $o . sign]} {
      if {$sign eq "+"} {
      } else {
      }
    }
  }
  return 1
}

proc COMMENT {inSrc tailCaptureIgnore ostrm} {
  # Allow comments in an input file which have no effect on output.
  return 1
}

proc INCLUDE {inSrc tailCaptureIncType ostrm} {
  # If invoked with a bare filename, include the named file. If invoked
  # with the parenthesized word form, include a file named by means of
  # the '-it <inc_type>=filename' command line option, provided that the
  # word matches a specified <inc_type>. Otherwise, do nothing.
  foreach {it rfpath} $tailCaptureIncType break
  foreach { srcFile istrm srcPrecLines } $inSrc break
  set saySkip ""
  if {$it ne ""} {
    if {[info exists ::incTypes($it)]} {
      set rfpath $::incTypes($it)
      if {![file exists [project_path $rfpath]]} {
        set saySkip "/* INCLUDE($it), of missing \"$rfpath\" skipped. */"
      }
    } else {
      set saySkip "/* INCLUDE($it), undefined and skipped. */"
    }
  }
  if {$saySkip ne ""} {
    emit_sync [list $saySkip] $ostrm $srcPrecLines $srcFile
  } else {
    process_file [project_path $rfpath] $ostrm
    incr srcPrecLines
    emit_sync {} $ostrm $srcPrecLines $srcFile
  }
  return 1
}

proc COLLECT_HELP_TEXT {inSrc tailCaptureEmpty ostrm} {
  # Collect help text table values, along with ordering info.
  foreach { srcFile istrm srcPrecLines } $inSrc break
  set iAte 2
  set help_frag {}
  set lx [gets $istrm]
  while {![eof $istrm] && ![regexp {^\s*\];} $lx]} {
    lappend help_frag $lx
    set lx [gets $istrm]
    incr iAte
  }
  set chunked_help [chunkify_help $help_frag]
  array set ::cmd_help $chunked_help
  foreach {cmd _} $chunked_help { set_src_tags help $cmd $inSrc }
  return $iAte
}

proc CONDITION_COMMAND {inSrc tailCap ostrm} {
  # Name a command to be conditionally available, with the condition.
  foreach {cmd pp_expr} $tailCap { set pp_expr [string trim $pp_expr] ; break }
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
  set_src_tags conditional $cmd $inSrc
  return 1
}

proc DISPATCH_CONFIG {inSrc tailCaptureEmpty ostrm} {
  foreach { srcFile istrm srcPrecLines } $inSrc break
  # Set parameters affecting generated dispatchable command function
  # signatures and generated dispatch table entries.
  set iAte 2
  set def_disp {}
  set lx [gets $istrm]
  while {![eof $istrm] && ![regexp {^\s*\];} $lx]} {
    lappend def_disp $lx
    set lx [gets $istrm]
    incr iAte
  }
  foreach line $def_disp {
    if {[regexp {^\s*(\w+)=(.+)$} $line ma k v]} {
      set ::dispCfg($k) $v
    }
  }
  return $iAte
}

proc DISPATCHABLE_COMMAND {inSrc tailCapture ostrm} {
  # Generate and emit a function definition, maybe wrapped as set by
  # CONDITION_COMMAND(), and generate/collect its dispatch table entry,
  # as determined by its actual arguments and DISPATCH_CONFIG parameters.
  foreach { srcFile istrm srcPrecLines } $inSrc break
  set args [lindex $tailCapture 0]
  set tc [lindex $tailCapture 1]
  if {$tc ne $::lb} {
    yap_usage "DISPATCHABLE_COMMAND($args)$tc" DISPATCHABLE_COMMAND
    incr $::iShuffleErrors
    return 0
  }
  set iAte 1
  set args [split [regsub {\s+} [string trim $args] " "]]
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
    while {![eof $istrm]} {
      set bl [gets $istrm]
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
      set mcInit [subst $::dispCfg(METACMD_INIT)]
      emit_conditionally $cmd [linsert $body 0 $funcOpen] $inSrc $ostrm
      set ::cmd_dispatch($cmd) [list $dispEntry]
      set ::metacmd_init($cmd) $mcInit
      set_src_tags dispatch $cmd $inSrc
    }
  }
  return $iAte
}

proc EMIT_DISPATCH {inSrc tailCap ostrm} {
  # Emit the collected dispatch table entries, in command order, maybe
  # wrapped with a conditional construct as set by CONDITION_COMMAND().
  foreach cmd [lsort [array names ::cmd_dispatch]] {
    emit_conditionally $cmd $::cmd_dispatch($cmd) $inSrc $ostrm $tailCap
  }
  return 1
}

proc EMIT_METACMD_INIT {inSrc tailCap ostrm} {
  # Emit the collected metacommand init table entries, in command order, maybe
  # wrapped with a conditional construct as set by CONDITION_COMMAND(). Prior
  # to the emit, substitute markers <HT{0,1}> with help text for the command.
  foreach cmd [lsort [array names ::metacmd_init]] {
    set initem $::metacmd_init($cmd)
    set ht0i -1
    if {[info exists ::cmd_help($cmd)]} {
      set ht $::cmd_help($cmd) ; # ht is a list.
      # HT0 is its content through first trailing comma.
      # HT1 is the remainder.
      for {set itc 0} {$itc < [llength $ht]} {incr itc} {
        if {[regexp {,\w*$} [lindex $ht $itc]]} {
          set ht0i $itc
          break
        }
      }
    }
    if {$ht0i != -1} {
      set ht0 [regsub {,\w*$} [join [lrange $ht 0 $ht0i] "\n"] "\n"]
      incr ht0i
      set ht1 [regsub {,\w*$} [join [lrange $ht $ht0i end] "\n"] "\n"]
      set ht0 "\n$ht0"
      set ht1 "\n$ht1"
    } else {
      set ht0 {0 /* help or commas missing */}
      set ht1 0
    }
    set initem [regsub {<HT0>} $initem $ht0]
    set initem [regsub {<HT1>} $initem $ht1]
    set initem [split $initem "\n"]
    emit_conditionally $cmd $initem $inSrc $ostrm $tailCap
  }
  return 1
}

proc EMIT_HELP_TEXT {inSrc tailCap ostrm} {
  # Emit the collected help text table entries, in command order, maybe
  # wrapped with a conditional construct as set by CONDITION_COMMAND().
  foreach htc [lsort [array names ::cmd_help]] {
    emit_conditionally $htc $::cmd_help($htc) $inSrc $ostrm $tailCap
  }
  return 1
}

proc say_usage {macros {extra {}}} {
  puts stderr "Usage:$extra"
  foreach m $macros {puts stderr "  $m$::macroUsages($m)"}
}
proc yap_usage {got macro} {
  puts stderr "Bad macro use: $got"
  say_usage $macro
}

# Perform any input collection or deferred output emits specified by a macro.
# Return number of input lines consumed, or 0 if not a recognized macro.
# This function may consume additional lines via triple inSrc.
proc do_macro {inSrc lx ostrm} {
  if {![regexp $::macroKeywordTailRE $lx ma macro tail] \
          || ![info exists ::macroTailREs($macro)]} {
    return 0
  }
  # It's an attempted macro invocation line. Process or fail and yap.
  set tailCap [regexp -inline $::macroTailREs($macro) $tail]
  # Call like-named proc with any args captured by the corresponding RE.
  return [$macro $inSrc [lrange $tailCap 1 end] $ostrm]
}

array set ::typedefsSeen {}
array set ::includesDone {}

# Filter redundant typedefs and certain includes and qualifiers, in place.
# Return 1 if line can be emitted as-is, 0 if to be processed further.
# In either case, the line named by $lineVar may have been changed.
proc transform_line {lineVar nesting} {
  upvar $lineVar line
  if {[regexp {^typedef .*;} $line]} {
    if {[info exists ::typedefsSeen($line)]} {
      set line "/* $line */"
      return 1
    }
    if {[regexp {\s(\w+)\s*;} $line _ tdname]} {
      if {[info exists ::typedefsSeen($tdname)]} {
        set line "/* [regsub {;} $line {; **/}]"
        return 1
      }
      set ::typedefsSeen($tdname) 1
    } else {
      set ::typedefsSeen($line) 1
    }
    return 0
  } elseif {$nesting == 0} {
    return 0
  }
  if {[regexp {^#include "sqlite.*"} $line]
    || [regexp {^# *include "test_windirent.h"} $line]} {
    set line "/* $line */"
    return 1
  }
  if {$nesting > 0 && [regexp {^#include "([\w\.]+)"} $line _ incRelPath]} {
    set fromPath [lindex $::incFileStack end]
    set incPath [file join [file dirname $fromPath] $incRelPath]
    set inTree [file exists $incPath]
    if {$inTree} {
      if {[info exists ::includesDone($incPath)]} {
        set line "/* $line */"
        return 1
      } else {
        set line "INCLUDE $incRelPath"
        set ::includesDone($incPath) 1
        return 0
      }
    }
  }
  if {[string first "__declspec(dllexport)" $line] >= 0} {
    set line [string map [list __declspec(dllexport) {}] $line]
    return 1
  }
  return 0
}


set ::incFileStack {}

# Read a named file and process its content to given output stream.
# Global ::incStack is maintained to support diagnostics.
# There is no (meaningful) return.
#
proc process_file { inFilepath ostrm } {
  set linesRead 0
  if { [catch {set istrm [open $inFilepath r]}] } {
    return -code error "Cannot read $inFilepath"
  } else {
    fconfigure $istrm -translation auto
    set nesting [llength $::incFileStack]
    lappend ::incFileStack $inFilepath
    set inFns [list $inFilepath $istrm]
    if {$nesting > 0} {
      set sayPath [string map [list \
                               "$::topDir/src/.." <projectDir> \
                               "$::topDir/src" <projectDir>/src \
                              ] $inFilepath]
      set splats [string repeat * [expr {33 - [string length $sayPath]/2 }]]
      set sayFile [list "/*$splats Begin $sayPath $splats*/"]
    } else { set sayFile {} }
    emit_sync $sayFile $ostrm $linesRead $inFilepath
    while {1} {
      set lin [gets $istrm]
      if {[eof $istrm]} break
      if {![transform_line lin $nesting]} {
        set ni [do_macro [concat $inFns $linesRead] $lin $ostrm]
        if {$ni > 0} {
          incr linesRead $ni
          continue
        }
      }
      emit_sync [list $lin] $ostrm $linesRead
      incr linesRead
    }
    if {$nesting > 0} {
      set sayFile [list "/**$splats End $sayPath $splats**/"]
      emit_sync $sayFile $ostrm $linesRead $inFilepath
    }
    set ::incFileStack [lrange $::incFileStack 0 end-1]
    close $istrm
  }
}

if {$runMode == "help"} {
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
} elseif {$runMode == "details"} {
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
} elseif {$runMode == "parameters"} {
  puts stderr $::parametersHelp
  exit 0
}

if {$runMode == "normal"} {
  fconfigure $outStrm -translation {auto lf}
  emit_sync [list $::headComment] $outStrm $::headCommentLines
  foreach {f} $::inFiles {
    process_file $f $outStrm
  }
  close $outStrm
}

exit $::iShuffleErrors
