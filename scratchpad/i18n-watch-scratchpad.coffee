fs = require 'fs'
path = require 'path'
exec = require( 'child_process' ).exec
async = require 'async'
xpath = require 'xpath'
dom = require( 'xmldom' ).DOMParser
require( "natural-compare-lite" )

rootworkdir = '/tmp/i18n'
fs.mkdirSync rootworkdir unless fs.existsSync rootworkdir

gitCommand = ( absworkdir, command ) ->
  "git --work-tree=#{absworkdir} --git-dir=#{absworkdir}/.git #{command}"

gitStep = ( absworkdir, params ) ->
  return  ( previousstdout, callback ) ->
    callback = previousstdout unless callback
    command = gitCommand absworkdir, params
    exec command, ( error, stdout, stderr ) ->
      console.log command
      console.log stdout unless error
      console.log "Error #{error} : stderr: #{stderr}" if error
      callback error, stdout

processProject = ( info ) ->
  absworkdir = path.join rootworkdir, info.workdir
      
  if info.inprogress
    console.log "#{info.giturl} branch #{info.branch} is already in progress"
    return
  
  info.inprogress = true
        
  if fs.existsSync absworkdir
    console.log "Checking for updates"
    async.waterfall [
      # Pull latest changes
      gitStep( absworkdir, "pull" ) ,
      
      # Check for new commites
      gitStep( absworkdir, 'log --pretty=format:\"{\\"hash\\":\\"%H\\", \\"author\\":\\"%an\\", \\"date\\":\\"%ar\\"},\"' ),
      
      # Parse output
      ( result, callback ) ->
        gitlog = JSON.parse "[#{result.slice(0, - 1)}]"
        console.log "Log:"
        for log in gitlog
          console.log "  #{log.hash}"
  
        # Check if there is a new commit. If not, return and it will abort the chain.
        if info.lastknowncommit == gitlog[0]?.hash
          info.inprogress = false
          return
        
        console.log "New commit for #{info.giturl} branch #{info.branch}"

        # Trigger a mvn clean, 
        # module: ftk-i18n-extract
        # goal: process-resources
        # profile: i18n-xliff-extract
        command = "mvn -f #{absworkdir}/pom.xml -P i18n-xliff-extract process-resources" # TODO clean
        exec command, ( error, stdout, stderr ) ->
          console.log command
          console.log stdout unless error
          console.log "Error #{error} : stderr: #{stderr}" if error
          callback error
      ,
      ( callback ) ->
        getUntranslatedKeyInProject absworkdir, callback
    ], ( err, keys ) ->
      console.log err if err
      for key in keys
        console.log key
      # TODO set info.lastknowncommit
      info.inprogress = false
  
  else
    # TODO Clone inline with request
    console.log "Cloning repo #{info.giturl}"
    exec "git clone -b #{info.branch} #{info.giturl} #{absworkdir}", ( error, stdout, stderr ) ->
      console.log stdout
      if error
        console.log 'stderr: ' + stderr
        console.log 'exec error: ' + error

getUntranslatedKeyInProject = ( project, callback ) ->
  fs.readFile Path.resolve( project, 'ftk-i18n/src/main/xliff/SolsticeConsoleStrings_en.xlf' ), ( err, data ) ->
    if err
      callback ( err )
      return
    dom = new dom().parseFromString( data.toString() )
    nodes = xpath.select( "//trans-unit[target='']/@id", dom )
    untranslatedKeys = []
    for id in nodes
      untranslatedKeys.push id.value
    untranslatedKeys.sort String.naturalCompare
    callback null, untranslatedKeys
        
info =
  'giturl': 'https://github.com/MacKeeper/testi18nwatch.git'
  'branch': 'master'
  'workdir': '123'
        
processProject info