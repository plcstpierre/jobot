Path     = require 'path'

###  Configure ###
# Set path to adapter since we are using npm link for hubot dependency. See Readme
#process.env.HUBOT_ADAPTER_PATH=Path.resolve( "node_modules" ) + '/'
#console.log "Adapter path #{process.env.HUBOT_ADAPTER_PATH}"

exec = require('child_process').exec

exec 'hostname', (error, stdout, stderr) -> 
  hostname = stdout.trim()
  console.log "Hostname: '#{hostname}'"
  process.env.FILE_BRAIN_PATH="."
  process.env.HUBOT_XMPP_USERNAME="hubot@#{hostname}"
  process.env.HUBOT_XMPP_CONFERENCE_DOMAINS="conference.#{hostname}"
  process.env.HUBOT_XMPP_PASSWORD="hubot"
  process.env.HUBOT_XMPP_ROOMS="deploy@conference.#{hostname}"
  process.env.HUBOT_XMPP_HOST="localhost"
  process.env.HUBOT_XMPP_PORT="5222"
  process.env.HUDSON_TEST_MANAGER_URL='https://hudson.priv.8d.com:8443'
  process.env.I18N_WATCH_WORKDIR='/tmp/i18n'
  ##################
  
  require './run_hubot'
