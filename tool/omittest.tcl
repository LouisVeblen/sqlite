# Documentation for this script. This may be output to stderr
# if the script is invoked incorrectly.
set ::USAGE_MESSAGE {
This Tcl script is used to test the various compile time options 
available for omitting code (the SQLITE_OMIT_xxx options). It
should be invoked as follows:

    <script> ?test-symbol? ?-makefile PATH-TO-MAKEFILE? ?-skip_run?

The default value for ::MAKEFILE is "../Makefile.linux.gcc".

If -skip_run option is given then only the compile part is attempted.

This script builds the testfixture program and runs the SQLite test suite
once with each SQLITE_OMIT_ option defined and then once with all options
defined together. Each run is performed in a seperate directory created
as a sub-directory of the current directory by the script. The output
of the build is saved in <sub-directory>/build.log. The output of the
test-suite is saved in <sub-directory>/test.log.

Almost any SQLite makefile (except those generated by configure - see below)
should work. The following properties are required:

  * The makefile should support the "testfixture" target.
  * The makefile should support the "test" target.
  * The makefile should support the variable "OPTS" as a way to pass
    options from the make command line to lemon and the C compiler.

More precisely, the following two invocations must be supported:

  $::MAKEBIN -f $::MAKEFILE testfixture OPTS="-DSQLITE_OMIT_ALTERTABLE=1"
  $::MAKEBIN -f $::MAKEFILE test

Makefiles generated by the sqlite configure program cannot be used as
they do not respect the OPTS variable.
}


# Build a testfixture executable and run quick.test using it. The first
# parameter is the name of the directory to create and use to run the
# test in. The second parameter is a list of OMIT symbols to define
# when doing so. For example:
#
#     run_quick_test /tmp/testdir {SQLITE_OMIT_TRIGGER SQLITE_OMIT_VIEW}
#
#
proc run_quick_test {dir omit_symbol_list} {
  # Compile the value of the OPTS Makefile variable.
  set opts ""
  if {$::tcl_platform(platform)=="windows"} {
    append opts "OPTS += -DSQLITE_OS_WIN=1\n"
    set target "testfixture.exe"
  } else {
    append opts "OPTS += -DSQLITE_OS_UNIX=1\n"
  }
  foreach sym $omit_symbol_list {
    append opts "OPTS += -D${sym}=1\n"
  }

  # Create the directory and do the build. If an error occurs return
  # early without attempting to run the test suite.
  file mkdir $dir
  puts -nonewline "Building $dir..."
  flush stdout
  catch {
    file copy -force ./config.h $dir
    file copy -force ./libtool $dir
  }
  set fd [open $::MAKEFILE]
  set mkfile [read $fd]
  close $fd
  regsub {\ninclude} $mkfile "\n$opts\ninclude" mkfile
  set fd [open $dir/makefile w]
  puts $fd $mkfile
  close $fd
  
  set rc [catch {
    exec $::MAKEBIN -C $dir -f makefile clean $::TARGET >& $dir/build.log
  }]
  if {$rc} {
    puts "No good. See $dir/build.log."
    return
  } else {
    puts "Ok"
  }
  
  # Create an empty file "$dir/sqlite3". This is to trick the makefile out 
  # of trying to build the sqlite shell. The sqlite shell won't build 
  # with some of the OMIT options (i.e OMIT_COMPLETE).
  set sqlite3_dummy $dir/sqlite3
  if {$::tcl_platform(platform)=="windows"} {
    append sqlite3_dummy ".exe"
  }
  if {![file exists $sqlite3_dummy]} {
    set wr [open $sqlite3_dummy w]
    puts $wr "dummy"
    close $wr
  }

  if {$::SKIP_RUN} {
    #  puts "Skip testing $dir."
  } else {
    # Run the test suite.
    puts -nonewline "Testing $dir..."
    flush stdout
    set rc [catch {
      exec $::MAKEBIN -C $dir -f makefile test >& $dir/test.log
    }]
    if {$rc} {
      puts "No good. See $dir/test.log."
    } else {
      puts "Ok"
    }
  }
}


# This proc processes the command line options passed to this script.
# Currently the only option supported is "-makefile", default
# "../Makefile.linux-gcc". Set the ::MAKEFILE variable to the value of this
# option.
#
proc process_options {argv} {
  set ::MAKEBIN make                        ;# Default value
  if {$::tcl_platform(platform)=="windows"} {
    set ::MAKEFILE ./Makefile               ;# Default value on Windows
  } else {
    set ::MAKEFILE ./Makefile.linux-gcc     ;# Default value
  }
  set ::SKIP_RUN 1                          ;# Default to attempt test
  set ::TARGET testfixture                  ;# Default thing to build

  for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -regexp -- [lindex $argv $i] {
      -{1,2}makefile {
        incr i
        set ::MAKEFILE [lindex $argv $i]
      }
  
      -{1,2}nmake {
        set ::MAKEBIN nmake
        set ::MAKEFILE ./Makefile.msc
      }

      -{1,2}target {
        incr i
        set ::TARGET [lindex $argv $i]
      }

      -{1,2}skip_run {
        set ::SKIP_RUN 1
      }
      -{1,2}run {
        set ::SKIP_RUN 0
      }

      -{1,2}help {
        puts $::USAGE_MESSAGE
        exit
      }

      -.* {
        puts stderr "Unknown option: [lindex $argv i]"
        puts stderr $::USAGE_MESSAGE
        exit 1
      }

      default {
        if {[info exists ::SYMBOL]} {
          puts stderr [string trim $::USAGE_MESSAGE]
          exit -1
        }
        set ::SYMBOL [lindex $argv $i]
      }
    }
    set ::MAKEFILE [file normalize $::MAKEFILE]
  }
}

# Main routine.
#

proc main {argv} {
  # List of SQLITE_OMIT_XXX symbols supported by SQLite.
  set ::OMIT_SYMBOLS [list \
    SQLITE_OMIT_ALTERTABLE \
    SQLITE_OMIT_ANALYZE \
    SQLITE_OMIT_ATTACH \
    SQLITE_OMIT_AUTHORIZATION \
    SQLITE_OMIT_AUTOINCREMENT \
    SQLITE_OMIT_AUTOINIT \
    SQLITE_OMIT_AUTOMATIC_INDEX \
    SQLITE_OMIT_AUTORESET \
    SQLITE_OMIT_AUTOVACUUM \
    SQLITE_OMIT_BETWEEN_OPTIMIZATION \
    SQLITE_OMIT_BLOB_LITERAL \
    SQLITE_OMIT_BTREECOUNT \
    SQLITE_OMIT_CASE_SENSITIVE_LIKE_PRAGMA \
    SQLITE_OMIT_CAST \
    SQLITE_OMIT_CHECK \
    SQLITE_OMIT_COMPILEOPTION_DIAGS \
    SQLITE_OMIT_COMPLETE \
    SQLITE_OMIT_COMPOUND_SELECT \
    SQLITE_OMIT_CONFLICT_CLAUSE \
    SQLITE_OMIT_CTE \
    SQLITE_OMIT_DATETIME_FUNCS \
    SQLITE_OMIT_DECLTYPE \
    SQLITE_OMIT_DEPRECATED \
    SQLITE_OMIT_DESERIALIZE \
    SQLITE_OMIT_DISKIO \
    SQLITE_OMIT_EXPLAIN \
    SQLITE_OMIT_FLAG_PRAGMAS \
    SQLITE_OMIT_FLOATING_POINT \
    SQLITE_OMIT_FOREIGN_KEY \
    SQLITE_OMIT_GENERATED_COLUMNS \
    SQLITE_OMIT_GET_TABLE \
    SQLITE_OMIT_HEX_INTEGER \
    SQLITE_OMIT_INCRBLOB \
    SQLITE_OMIT_INTEGRITY_CHECK \
    SQLITE_OMIT_INTROSPECTION_PRAGMAS \
    SQLITE_OMIT_JSON \
    SQLITE_OMIT_LIKE_OPTIMIZATION \
    SQLITE_OMIT_LOAD_EXTENSION \
    SQLITE_OMIT_LOCALTIME \
    SQLITE_OMIT_LOOKASIDE \
    SQLITE_OMIT_MEMORYDB \
    SQLITE_OMIT_OR_OPTIMIZATION \
    SQLITE_OMIT_PAGER_PRAGMAS \
    SQLITE_OMIT_PARSER_TRACE \
    SQLITE_OMIT_POPEN \
    SQLITE_OMIT_PRAGMA \
    SQLITE_OMIT_PROGRESS_CALLBACK \
    SQLITE_OMIT_QUICKBALANCE \
    SQLITE_OMIT_RANDOMNESS \
    SQLITE_OMIT_REINDEX \
    SQLITE_OMIT_SCHEMA_PRAGMAS \
    SQLITE_OMIT_SCHEMA_VERSION_PRAGMAS \
    SQLITE_OMIT_SHARED_CACHE \
    SQLITE_OMIT_SHUTDOWN_DIRECTORIES \
    SQLITE_OMIT_SUBQUERY \
    SQLITE_OMIT_TCL_VARIABLE \
    SQLITE_OMIT_TEMPDB \
    SQLITE_OMIT_TEST_CONTROL \
    SQLITE_OMIT_TRACE \
    SQLITE_OMIT_TRIGGER \
    SQLITE_OMIT_TRUNCATE_OPTIMIZATION \
    SQLITE_OMIT_UPSERT \
    SQLITE_OMIT_UTF16 \
    SQLITE_OMIT_VACUUM \
    SQLITE_OMIT_VIEW \
    SQLITE_OMIT_VIRTUALTABLE \
    SQLITE_OMIT_WAL \
    SQLITE_OMIT_WINDOWFUNC \
    SQLITE_OMIT_WSD \
    SQLITE_OMIT_XFER_OPT \
  ]

  set ::ENABLE_SYMBOLS [list \
    SQLITE_ALLOW_ROWID_IN_VIEW \
    SQLITE_DISABLE_DIRSYNC \
    SQLITE_DISABLE_LFS \
    SQLITE_ENABLE_ATOMIC_WRITE \
    SQLITE_ENABLE_COLUMN_METADATA \
    SQLITE_ENABLE_EXPENSIVE_ASSERT \
    SQLITE_ENABLE_FTS3 \
    SQLITE_ENABLE_FTS3_PARENTHESIS \
    SQLITE_ENABLE_FTS4 \
    SQLITE_ENABLE_IOTRACE \
    SQLITE_ENABLE_LOAD_EXTENSION \
    SQLITE_ENABLE_LOCKING_STYLE \
    SQLITE_ENABLE_MEMORY_MANAGEMENT \
    SQLITE_ENABLE_MEMSYS3 \
    SQLITE_ENABLE_MEMSYS5 \
    SQLITE_ENABLE_OVERSIZE_CELL_CHECK \
    SQLITE_ENABLE_RTREE \
    SQLITE_ENABLE_STAT3 \
    SQLITE_ENABLE_UNLOCK_NOTIFY \
    SQLITE_ENABLE_UPDATE_DELETE_LIMIT \
  ]

  # Process any command line options.
  process_options $argv

  if {[info exists ::SYMBOL] } {
    set sym $::SYMBOL

    if {[lsearch $::OMIT_SYMBOLS $sym]<0 && [lsearch $::ENABLE_SYMBOLS $sym]<0} {
      puts stderr "No such symbol: $sym"
      exit -1
    }

    set dirname "test_[regsub -nocase {^x*SQLITE_} $sym {}]"
    run_quick_test $dirname $sym
  } else {
    # First try a test with all OMIT symbols except SQLITE_OMIT_FLOATING_POINT 
    # and SQLITE_OMIT_PRAGMA defined. The former doesn't work (causes segfaults)
    # and the latter is currently incompatible with the test suite (this should
    # be fixed, but it will be a lot of work).
    set allsyms [list]
    foreach s $::OMIT_SYMBOLS {
      if {$s!="SQLITE_OMIT_FLOATING_POINT" && $s!="SQLITE_OMIT_PRAGMA"} {
        lappend allsyms $s
      }
    }
    run_quick_test test_OMIT_EVERYTHING $allsyms
  
    # Now try one quick.test with each of the OMIT symbols defined. Included
    # are the OMIT_FLOATING_POINT and OMIT_PRAGMA symbols, even though we
    # know they will fail. It's good to be reminded of this from time to time.
    foreach sym $::OMIT_SYMBOLS {
      set dirname "test_[regsub -nocase {^x*SQLITE_} $sym {}]"
      run_quick_test $dirname $sym
    }
  
    # Try the ENABLE/DISABLE symbols one at a time.  
    # We don't do them all at once since some are conflicting.
    foreach sym $::ENABLE_SYMBOLS {
      set dirname "test_[regsub -nocase {^x*SQLITE_} $sym {}]"
      run_quick_test $dirname $sym
    }
  }
}

main $argv
