##
# Description
#   Monitor i18n key translation
#
# Dependencies:
#   none
#
# Configuration:
#   process.env.I18N_WATCH_WORKDIR: The working directory for git clone
#
# Commands:
#   hubot Watch translations on git repo {git url} branch {branch name} jvm {7|8} and broadcast to room {full room name}
#
# Author:
#   Manuel Darveau
#

fs = require 'fs'
path = require 'path'
async = require 'async'
xpath = require 'xpath'
DOMParser = require( 'xmldom' ).DOMParser
exec = require( 'child_process' ).exec
require( "natural-compare-lite" )

class I18nWatcher

  constructor: ( @robot, skipStart ) ->
    @state = {}
    @workdirlocks = {}
    @robot.logger.info "I18Watcher Loaded"

    unless process.env.I18N_WATCH_WORKDIR
      @robot.logger.error 'I18N_WATCH_WORKDIR not set'
      process.exit( 1 )

    @rootworkdir = process.env.I18N_WATCH_WORKDIR
    fs.mkdirSync @rootworkdir unless fs.existsSync @rootworkdir

    setInterval( @.loop, 1 * 60 * 1000 ) # unless skipStart
#
    # Tell Hubot to broadcast extract results to the specified room.
    robot.respond /Watch translations on git repo (\S*) branch (\S*) jvm (7|8) and broadcast to room (\S*)/i, ( msg ) =>
      repoURL = msg.match[1]
      branch = msg.match[2]
      room = msg.match[4]
      jvm = msg.match[3]

      unless repoURL
        msg.reply( "You must specify a repo url" )
        return

      unless branch
        msg.reply( "You must specify a branch" )
        return

      @watchProject repoURL, branch, room, jvm, ( message )->
        msg.send message

  loop: () =>
    # Check for new commits
    console.log ("Test!")
    @checkForChanges()

  watchProject: ( repoURL, branch, room, jvm, replyHandler ) ->
    javahome = "/usr/local/jvm/latest#{jvm}"
    info =
      giturl: repoURL
      branch: branch
      workdir: Math.random().toString( 36 ).substring( 10 )
      room: room
      jvm : javahome

    try
      replyHandler( "Cloning..." )
      @cloneRepo info, ( err ) =>
        if err
          replyHandler( "Clone failed: #{err}" )
        else
          @persist ( storage ) ->
            storage.projects.push info
          replyHandler( "Will watch translations of #{info.giturl} branch #{info.branch} in working dir #{info.workdir}" )
    catch e
      replyHandler( "Error: #{e}" )

  checkForChanges: () ->
    console.log "Looking for untranslated keys..."
    storage = @readstorage()
    for info in storage.projects
      do (info) =>
        absworkdir = path.join @rootworkdir, info.workdir
        if fs.existsSync absworkdir
          console.log "  for #{info.giturl} branch #{info.branch} in directory #{info.workdir}"
          @processProject info, ( err, info ) =>
            if err
              @sendGroupChatMesssage info.room, "Error checking for i18n on #{info.branch} see log"
              @robot.logger.error "Error checking for i18n on #{info.branch} ", err
              console.log err
            else
              return if info.untranslatedKeys.length == 0
              message = "Untranslated keys for #{info.giturl}/#{info.branch}:\n"
              for key in info.untranslatedKeys
                message += "  - #{key}\n"
              @sendGroupChatMesssage info.room, message
        else
          # TODO @mdarveau Remove from brain
          console.log "Working directory '#{absworkdir}' does not exists. Removing watch for #{info.giturl} branch #{info.branch}"
          @sendGroupChatMesssage info.room, "Working directory '#{absworkdir}' does not exists. Removing watch for #{info.giturl} branch #{info.branch}"
          console.log info
          storage.projects.splice(storage.projects.indexOf(info),1)
  # Storage
  persist: ( callback ) ->
    storage = @robot.brain.get 'I18nWatcher'
    storage?={}
    storage.projects?= []
    callback( storage )
    @robot.brain.set 'I18nWatcher', storage
    @robot.brain.save()

  readstorage: () ->
    storage = @robot.brain.get 'I18nWatcher'
    storage?={}
    storage.projects?= []
    return storage


#############################

  gitCommand: ( absworkdir, action ) ->
    command = "git "
    command += "--work-tree=#{absworkdir} --git-dir=#{absworkdir}/.git " if absworkdir
    command += action
    return command

  gitStep: ( absworkdir, params ) ->
    return  ( previousstdout, callback ) =>
      callback = previousstdout unless callback
      command = @gitCommand absworkdir, params
      console.log command
      exec command, ( error, stdout, stderr ) ->
        console.log stdout unless error
        console.log "Error #{error} : stderr: #{stderr}" if error
        callback error, stdout

  #
  #  info =
  #    giturl: The git repo URL
  #    branch: The branch name or master
  #    workdir: A unique working dir used for the clone/checkout
  #
  processProject: ( info, callback ) ->
    absworkdir = path.join @rootworkdir, info.workdir

    if @workdirlocks[info.workdir]
      console.log "#{info.giturl} branch #{info.branch} is already in progress"
      return

    @workdirlocks[info.workdir] = true

    console.log "Checking for updates"
    async.waterfall [
      # Cleanup
      @gitStep( absworkdir, "reset --hard" ) ,
      @gitStep( absworkdir, "clean -fd" ) ,

      # Prune /remove useless references
      @gitStep( absworkdir, "remote prune origin" ) ,

      # Pull latest changes
      @gitStep( absworkdir, "pull -p" ) ,

      # Check for new commites
      @gitStep( absworkdir, "log --pretty=format:\"{\\\"hash\\\":\\\"%H\\\", \\\"author\\\":\\\"%an\\\", \\\"date\\\":\\\"%ar\\\"},\" #{info.lastknowncommit}.." ),

      # Parse output
      ( result, callback ) =>
        gitlog = JSON.parse "[#{result.slice( 0, -1 )}]"
        latesthash = gitlog[0]?.hash

        # Check if there is a new commit. If not, return and it will abort the chain.
        unless latesthash
          delete @workdirlocks[info.workdir]
          console.log "No new commit for #{info.giturl} branch #{info.branch}. Last commit is '#{info.lastknowncommit}'"
          return

        console.log "New commit for #{info.giturl} branch #{info.branch}. Last commit is '#{latesthash}', previous last known was '#{info.lastknowncommit}'"

        # Call maven to extract i18n keys
        maven_opts = '"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=512M"'
        command = "export JAVA_HOME=#{info.jvm} && export MAVEN_OPTS=#{maven_opts} && mvn -f #{absworkdir}/pom.xml -pl ftk-i18n-extract -am -P i18n-xliff-extract clean compile process-resources"
        console.log command
        exec command,
          timeout: 20 * 60 * 1000 # 20 minutes
          maxBuffer: 15 * 1024 * 1024 # 15 MB
        , ( error, stdout, stderr ) ->
          # TODO Handle failure because of compile fail or other. Check error.code
          if error
            error = error + stderr + stdout
          #else
          #  console.log stdout
          callback error, latesthash
    ,
      ( latesthash, callback ) =>
        @getUntranslatedKeyInProject absworkdir, ( err, untranslatedKeys ) ->
          callback err, latesthash, untranslatedKeys

    ], ( err, latesthash, untranslatedKeys ) =>
      if err
        delete @workdirlocks[info.workdir]
        callback err, info
      else
        # store info
        @persist ( storage ) =>
          for storageinfo in storage.projects
            do (storageinfo) =>
              if storageinfo.giturl == info.giturl and storageinfo.branch == info.branch
                console.log "Storing latest hash '#{latesthash}' for #{info.giturl} branch #{info.branch}"
                storageinfo.lastknowncommit = latesthash
                storageinfo.untranslatedKeys = untranslatedKeys
                delete @workdirlocks[info.workdir]
                callback null, storageinfo
                return

  cloneRepo: ( info, callback ) ->
    absworkdir = path.join @rootworkdir, info.workdir
    console.log "Cloning repo #{info.giturl} to #{absworkdir}"
    async.waterfall [
      # Pull latest changes
      @gitStep( null, "clone -b #{info.branch} #{info.giturl} #{absworkdir}" ) ,

      # Check for new commites
      @gitStep( absworkdir, 'log --pretty=format:\"{\\"hash\\":\\"%H\\"}\" -n1' ),

      # Parse output
      ( result, callback ) ->
        gitlog = JSON.parse result
        info.lastknowncommit = gitlog.hash
        callback null, info.lastknowncommit

    ], ( err, lastknowncommit ) ->
      callback err, lastknowncommit

  getUntranslatedKeyInProject: ( project, callback ) ->
    fs.readFile path.resolve( project, 'ftk-i18n/src/main/xliff/SolsticeConsoleStrings_en.xlf' ), ( err, data ) ->
      if err
        callback ( err )
        return
      dom = new DOMParser().parseFromString( data.toString() )
      nodes = xpath.select( "//trans-unit[target='']/@id", dom )
      untranslatedKeys = []
      for id in nodes
        untranslatedKeys.push id.value
      untranslatedKeys.sort String.naturalCompare
      callback null, untranslatedKeys

#############################

  sendGroupChatMesssage: ( to_jid, message ) ->
    envelope =
      room: to_jid
      user:
        type: 'groupchat'
    @robot.send( envelope, message )

module.exports = ( robot, skipStart ) ->
  new I18nWatcher( robot, skipStart )

#watcher = new I18nWatcher();
#watcher.getUntranslatedKeyInProject '/Users/mdarveau/git_workspace/ftk', ( err, keys ) ->
#  console.log err if err
#  for key in keys
#    console.log key
