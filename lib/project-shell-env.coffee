{ spawnSync } = require "child_process"
{ Disposable, CompositeDisposable } = require "atom"

##
# Helper function: prints debug statement into atom's console if it started in dev mode.
#
debug = ( statements... ) ->
  if atom.inDevMode()
    console.log "[project-shell-env]", statements...

##
# Helper function: escapes a string so that it can be safely used in a shell command line.
#
# @param [String] string
# @return [String]
#
shellEscape = ( string ) ->
  return string.replace( /([^A-Za-z0-9_\-.,:\/@])/, "\\$1" )

##
# Returns shell environment variables in the given directory as string.
#
# @param [String] path
# @return [String]
#
getShellEnv = ( path ) ->
  # SHELL env variable contains user's shell even when atom is launched from GUI
  shell = process.env[ "SHELL" ] ? "bash"

  # List of flags with which shell will be invoked
  shellFlags = [
    "-l", # We must use login shell to load user environment
    "-i"  # We must use interactive shell to ensure user config is loaded
  ]

  # Marker string to mark command output
  marker = "--- 8< ---"

  # Script that will be passed as stdin to the shell
  shellScript = [
    # Change directory or exit
    # NB: some tools (eg. RVM) can redefine "cd" command to execute some code
    "cd #{shellEscape path} || exit -1",

    # Print env inside markers
    "echo '#{marker}' && env && echo '#{marker}'",

    # Exit shell
    "exit"
  ]

  # Spawn shell process and execute script
  # NB: we can't use "exec" because we need full-fledged login interactive shell
  # with command prompt because some tools (eg. direnv) may use PROMPT_COMMAND
  # to execute some code; we also can't use "spawn" because we need to block
  # atom until shell variable are loaded.
  shellResult = spawnSync shell, shellFlags,
    input:   shellScript.join( "\n" )
    timeout: 1000 # Maximum 1 second to execute

  # Throw timeout error
  throw shellResult.error if shellResult.error

  # Throw execution error
  throw new Error( shellResult.stderr.toString()) if shellResult.status != 0

  # Extract env from shell output
  shellStdout = shellResult.stdout.toString()

  return shellStdout.substring( shellStdout.indexOf( marker ) + marker.length,
                                shellStdout.lastIndexOf( marker ))

##
# Parses output of "env" utility and returns variable as hash.
#
# @param [String] envOutput
# @return [Object]
#
parseShellEnv = ( shellEnv ) ->
  env = {}

  shellEnv.trim().split( "\n" ).forEach ( line ) ->
    # Search for position of first occurrence of equal sign or throw error if it is not found
    ( eqlSign = line.indexOf( "=" )) > 0 or throw new Error( "Invalid env line: #{line}" )

    # Split string by found equal sign
    [ name, value ] = [ line.substring( 0, eqlSign ), line.substring( eqlSign + 1 ) ]

    env[ name ] = value

  return env

##
# Filters env variables using blacklist.
#
# @param [Object] env
# @param [Object] blacklist
# @return [Object]
#
filterEnv = ( env, blacklist = [] ) ->
  allowedVariables = Object.keys( env )

  # Apply blacklist
  if blacklist
    allowedVariables = allowedVariables.filter ( key ) -> key not in blacklist

  filteredEnv = {}
  filteredEnv[ key ] = env[ key ] for key in allowedVariables

  return filteredEnv

##
# Sets environment variables for current atom process. Returns disposable that
# will rollback all changes made.
#
# @param [Object] env variables
# @return [Disposable]
#
setAtomEnv = ( env ) ->
  # Disposable that will rollback all changes made to env
  disposable = new CompositeDisposable

  Object.keys( env ).forEach ( name ) ->
    newValue = env[ name ]
    oldValue = process.env[ name ]

    # Do nothing if env variable already set
    return if newValue == oldValue

    disposable.add new Disposable ->
      # If env variable wasn't changed set it back to original value
      if process.env[ name ] == newValue
        debug "#{name}: #{newValue} -> #{oldValue}"

        if oldValue?
          process.env[ name ] = oldValue
        else
          delete process.env[ name ]
      else
        debug "#{name} was changed – will not rollback to #{oldValue}"

    debug "#{name}: #{oldValue} -> #{newValue}"

    # Set new value
    process.env[ name ] = newValue

  return disposable

##
# Package class.
#
class ProjectShellEnv
  # ENV variables that NEVER will be loaded
  IGNORED_ENV = [
    "_",    # Contains previous command executed. Always equals to "env"
    "SHLVL" # How deeply Bash is nested. Always equals to 3
  ]

  config:
    blacklist:
      order: 1
      description: "List of environment variables which will be ignored."
      type: "array"
      default: []
      items:
        type: "string"

  activate: =>
    # Add our commands
    @commandsDisposable = atom.commands.add "atom-workspace",
      "project-shell-env:load": this.load,
      "project-shell-env:reset": this.reset

    # Automatically load env variables when atom started
    this.load()

  deactivate: =>
    # Delete our commands and return original env variables
    @envDisposable?.dispose() and delete @envDisposable
    @commandsDisposable?.dispose() and delete @commandsDisposable

  load: =>
    # Unload previous set variables
    this.reset()

    # Get project root path
    # TODO: we doesn't support multiple projects in 1 window!
    projectRoot = atom.project.getPaths()[ 0 ]

    debug "project root: #{projectRoot}"

    # Combine system and user's blacklists
    envBlacklist = [].concat( IGNORED_ENV ).concat( atom.config.get( "project-shell-env.blacklist" ))

    debug "blacklisted vars:", envBlacklist

    # Set project variables
    try
      @envDisposable = setAtomEnv( filterEnv( parseShellEnv( getShellEnv( projectRoot )), envBlacklist ))
    catch err
      # Throw error so specs will fail
      if atom.inSpecMode()
        throw err
      else
        atom.notifications.addError( err.toString(), dismissable: true )

  reset: =>
    @envDisposable?.dispose() and delete @envDisposable

module.exports = new ProjectShellEnv
