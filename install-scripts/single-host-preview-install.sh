#!/bin/bash

# print command line usage syntax
function usage {
	local cmd=`basename $0`
	echo "
Usage:

  The CodeStream On-Prem Administration Guide is here:

    https//docs.codestream.com/onprem/

  Quick Start
    $cmd --quickstart                        # Configure and start CodeStream

  Container Control
    $cmd [-M] -a { install | start | stop | restart | reset | status | start_mongo }

  Maintenance and Support
    $cmd --apply-support-pkg <support-pkg>   # apply the codestream-provided support package
    $cmd --backup                            # backup mongo database
    $cmd --create-mst-app-pkg <app-id> <public-api-host>    # create a custom MST App Package
    $cmd --full-backup                       # backup mongo and the entire configuration directory
    $cmd --logs {Nh | Nm}                    # collect last N hours or minutes of logs
    $cmd --repair-db <repair-script.js>      # run mongo repair commands
    $cmd --restore {latest | <file>}         # restore mongo database from latest backup or <file>
    $cmd --run-api-utility <script>          # run an api utility in the API container
    $cmd --run-support-script <script>       # run a support script located in $codestreamRoot/support/
    $cmd --undo-stack                        # print the undo stack
    $cmd --update-containers [--no-start] [--no-backup]  # grab latest container versions (performs backup)
    $cmd --update-myself                     # update the codestream control script and utilities
    $cmd --run-python-script <script> <opts> # run a python script using the codestream python container
"
	if [ "$1" == help ]; then
		echo "
  Initialization of CodeStream and container control (-a)

    install   create the config file and prepare the CodeStream environment
    start     run or start the CodeStream containers
    status    check the docker status of the containers
    stop      stop the CodeStream containers
    reset     stop and remove the containers
    start_mongo  start the mongodb container only

        >>>  mongo data _should_ persist a mongo container reset, but  <<<
        >>>  make sure you back up the data with --backup beforehand   <<<

    Note: specify -M or set environment variable CS_MONGO_CONTAINER=ignore to exclude
    mongo when running the commands above
"
	fi
	exit 1
}

# prompt for a yes or no answer to a question
#
# args:
#    prompt     message to display
# returns:
#    0   no
#    1   yes
function yesno {
	local prompt=$1
	local ans
	echo -n "$prompt"
	read ans
	while [ "$ans" != "y" -a "$ans" != "n" ]; do
		echo -n "y or n ? "
		read ans
	done
	[ $ans == "y" ] && return 1
	return 0
}

# generate a random string of characters of specified length (relies on /dev/urandom)
function random_string {
	local strLen=$1
	[ ! -c /dev/urandom ] && echo "the /dev/urandom device was not found - cannot generate a random string" && exit 1
	[ -z "$strLen" ] && strLen=18
	head /dev/urandom | $TR_CMD -dc A-Za-z0-9 | head -c $strLen ; echo ''
}

# check for core commands this script needs to work
function check_env {
	local rc=0
	local cmd
	[ -z "$HOME" ] && echo "\$HOME is not defined" >&2 && rc=1
	for cmd in docker curl $TR_CMD touch
	do
		[ -z `which $cmd 2>/dev/null` ] && echo "'$cmd' command not found in search path" >&2 && rc=1
	done
	return $rc
}

# download designated utility scripts
# args:
#     force-flag       non-null string forces download of all utilities
function fetch_utilities {
	local force_fl="$1"
	[ ! -d $codestreamRoot/util ] && mkdir $codestreamRoot/util
	for u in dt-merge-json
	do
		if [ ! -f $codestreamRoot/$u -o -n "$force_fl" ]; then
			# echo "Fetching $u ..."
			curl https://raw.githubusercontent.com/TeamCodeStream/onprem-install/$installBranch/install-scripts/util/$u -o $codestreamRoot/util/$u -s
			[ $? -ne 0 ] && echo "error fetching $u" && exit 1
			chmod 750 $codestreamRoot/util/$u
		fi
	done
}

# download the latest version of this script in place (then immediately exit)
function update_myself {
	fetch_utilities --force
	(
		curl https://raw.githubusercontent.com/TeamCodeStream/onprem-install/$installBranch/install-scripts/codestream -o $codestreamRoot/codestream -s
		chmod +x $codestreamRoot/codestream
	)
	# this is special - WE GO NO FURTHER AFTER UPDATING OURSELF BECAUSE THE BASH INTERPRETER IS LIKELY TO BARF
	exit 0
}

# uupdate the file containing the container versions for this codestream release
# args:
#     undoId (optional)     for storing existing file(s) in the undo stack
# returns:
#      0   successfully updated
#      1   no update necessary
#      2   error during update
function update_container_versions {
	local undoId="$1"
	curl -s --fail --output $codestreamRoot/container-versions.new "$versionUrl$releaseSufx"
	[ $? -ne 0 ] && echo "Failed to download container versions ($versionUrl$releaseSufx)" && return 2
	if [ ! -f $codestreamRoot/container-versions ]; then
		/bin/mv $codestreamRoot/container-versions.new $codestreamRoot/container-versions || return 2
		return 0
	fi
	x=`diff $codestreamRoot/container-versions.new $codestreamRoot/container-versions|wc -l`
	[ "$x" -eq 0 ] && /bin/rm -f $codestreamRoot/container-versions.new && return 1
	[ -z "$undoId" ] && undoId=$(undo_stack_id "" "called update container versions()")
	/bin/mv -f $codestreamRoot/container-versions $codestreamRoot/.undo/$undoId/container-versions || return 2
	/bin/mv -f $codestreamRoot/container-versions.new $codestreamRoot/container-versions || return 2
	return 0
}

# source in the container version file.
#
# This contains the versions of each docker image to use as well as optional
# docker hub repo names. Default repo names will be those for GA (master)
#
# args:
#   undoId    optional undo stack Id
function load_container_versions {
	local undoId="$1"
	[ ! -f $codestreamRoot/container-versions ] && { update_container_versions "$undoId" "called load_container_versions()" || exit 1; }
	apiRepo=""
	broadcasterRepo=""
	mailoutRepo=""
	rabbitmqRepo=""
	pythonRepo=""
	. $codestreamRoot/container-versions || exit 1
	[ -z "$apiRepo" ] && apiRepo="teamcodestream/api-onprem"
	[ -z "$broadcasterRepo" ] && broadcasterRepo="teamcodestream/broadcaster-onprem"
	[ -z "$mailoutRepo" ] && mailoutRepo="teamcodestream/mailout-onprem"
	[ -z "$rabbitmqRepo" ] && rabbitmqRepo="teamcodestream/rabbitmq-onprem"
	[ -z "$pythonRepo" ] && pythonRepo="teamcodestream/dt-python3"
}

# With the addition of a second starting template, the name of the template
# saved in $codestreamRoot has been changed to be more generic.
function migrate_config_file_template {
	if [ -f $codestreamRoot/single-host-preview-minimal-cfg.json.template ]; then
		echo "Migrating config file template to single-host-preview-cfg.json.template"
		mv $codestreamRoot/single-host-preview-minimal-cfg.json.template $codestreamRoot/single-host-preview-cfg.json.template
	fi
}

# moving to an aptly-named control script
# function migrate_control_script {
# 	if [ -f $codestreamRoot/codestream -a -f $codestreamRoot/single-host-preview-install.sh ]; then
# 		if [ `basename $0` == codestream ]; then
# 			echo -e '#!/bin/bash\n\necho "single-host-preview-install.sh is deprecated. Please run codestream script instead.\n\n" >&2' >$codestreamRoot/single-host-preview-install.sh
# 			chmod +x $codestreamRoot/single-host-preview-install.sh
# 		else
# 			echo -e "\n$0 is deprecated. The new script is called 'codestream'. Please run that instead\n"
# 			exit 1
# 		fi
# 	fi
# }

# fetch the latest configuration file template from the onprem-install repo
function get_config_file_template {
	local undoId="$1" config="$2"
	[ -z "$config" ] && config=quickstart && echo "Installing with $config config"
	if [ -f $codestreamRoot/single-host-preview-cfg.json.template ]; then
		[ -z "$undoId" ] && undoId=$(undo_stack_id "" "called get_config_file_template()")
		cp -p $codestreamRoot/single-host-preview-cfg.json.template $codestreamRoot/.undo/$undoId
	fi
	echo "Fetching updated config file template..."
	[ $debugMode -eq 1 ] && echo curl -s https://raw.githubusercontent.com/TeamCodeStream/onprem-install/$installBranch/config-templates${releasePath}/single-host-preview-$config-cfg.json.template -o $codestreamRoot/single-host-preview-cfg.json.template >&2
	curl -s https://raw.githubusercontent.com/TeamCodeStream/onprem-install/$installBranch/config-templates${releasePath}/single-host-preview-$config-cfg.json.template -o $codestreamRoot/single-host-preview-cfg.json.template || { echo "error getting config template" >&2; exit 1; }
	chmod 660 $codestreamRoot/single-host-preview-cfg.json.template || exit 1
}

# update the configuration file from the latest template using the dt-merge-json
# utility script executed by the CodeStream pre-configured python container
function update_config_file {
	local undoId="$1"
	[ -z "$undoId" ] && undoId=$(undo_stack_id "" "called update_config_file()")
	echo "updating config file"
	cp -p $codestreamRoot/codestream-services-config.json $codestreamRoot/.undo/$undoId/
	get_config_file_template $undoId
	# update config file with new template data
	[ $debugMode -eq 1 ] && echo "run_python_script /cs/util/dt-merge-json --existing-file /cs/.undo/$undoId/codestream-services-config.json --onprem-update-mode --new-file /cs/single-host-preview-cfg.json.template >$codestreamRoot/codestream-services-config.json.new" >&2
	run_python_script /cs/util/dt-merge-json --existing-file /cs/.undo/$undoId/codestream-services-config.json --onprem-update-mode --new-file /cs/single-host-preview-cfg.json.template >$codestreamRoot/codestream-services-config.json.new
	if [ $rc -ne 0 -o ! -s $codestreamRoot/codestream-services-config.json.new ]; then
		echo "There was a problem updating the config file!!!" >&2
		/bin/rm -f $codestreamRoot/codestream-services-config.json.new
		exit 1
	fi
	/bin/mv -f $codestreamRoot/codestream-services-config.json.new $codestreamRoot/codestream-services-config.json
}

# optionally fetch and execute a CodeStream supplied support package.
#
# Support packages are tarballs containing custom scripts CodeStream support
# prepares for specific problems with client installations.
function apply_support_package {
	local supportPkg=$1
	shift
	local curDir=`pwd`
	[ -z "$supportPkg" ] && echo "support pacakge filename is required" && return 1
	supportPkgFile=`basename $supportPkg`

	[ ! -d $codestreamRoot/support ] && { mkdir $codestreamRoot/support || return 1; }
	local supportId=`date +%Y%m%d.%H%M%S.%s`
	local supportDir="$HOME/.codestream/support/$supportId"
	echo "mkdir $supportDir" && mkdir $supportDir || return 1

	if [ "`echo $supportPkg | grep -c ^https:`" -gt 0 ]; then
		echo "Fetching support package with curl"
		curl $supportPkg -o $supportDir/$supportPkgFile -s || { echo "could not download support package" && return 1; }
	else
		[ ! -f "$supportPkg" ] && echo "$supportPkg not found" && return 1
		/bin/cp $supportPkg $supportDir || return 1
	fi

	cd $supportDir || return 1
	tar -xzf $supportPkgFile || { echo "untar $supportPkgFile failed" && return 1; }

	[ ! -f start-here.sh ] && echo "missing start script" && return 1
	echo running package - /bin/bash ./start-here.sh "$@"
	/bin/bash ./start-here.sh "$@"
	return $?
}

# execute a script from the host OS disk using an API container
function run_support_script {
	local script_name=$1
	[ -z "$script_name" ] && "script name required" && return 1
	script_name=`basename $script_name`
	[ ! -d $codestreamRoot/support ] && { mkdir $codestreamRoot/support || return 1; }
	[ ! -f $codestreamRoot/support/$script_name ] && { echo "$codestreamRoot/support/$script_name not found" && return 1; }
	docker run --rm -v $codestreamRoot:/opt/config --network=host $apiRepo:$apiDockerVersion node /opt/config/support/`basename $script_name`
	return $?
}

# execute a utility script included within an API container
function run_api_utility {
	local util_name=$1
	[ -z "$util_name" ] && "utility name required" && return 1
	shift
	echo docker run --rm -v $codestreamRoot:/opt/config --network=host $apiRepo:$apiDockerVersion node /opt/api/api_server/bin/$util_name "$@"
	docker run --rm -v $codestreamRoot:/opt/config --network=host $apiRepo:$apiDockerVersion node /opt/api/api_server/bin/$util_name "$@"
	return $?
}

# Execute the docker update procedure
function update_containers_except_mongo {
	local parm nostart nobackup
	for parm in $*; do
		[ $parm == "--no-start" ] && nostart=1
		[ $parm == "--no-backup" ] && nobackup=1
	done
	local undoId=$(undo_stack_id "" "full container update procedure")
	backup_dot_codestream $undoId
	stop_containers 0
	[ -z "$nobackup" ] && { backup_mongo $FQHN $undoId || exit 1; }
	remove_containers 0
	update_container_versions $undoId
	local rc=$?
	[ $rc -eq 2 ] && echo "error updating containers">&2 && exit 1
	if [ $rc -eq 0 ]; then
		load_container_versions $undoId
		update_config_file $undoId
	else
		echo "You are already running the latest container versions"
	fi
	[ -z "$nostart" ] && start_containers 0
}

# generate an undo stack Id and creates its directory
#
# An undo stack Id is a top leveel directory in $codestreamRoot/.undo/ where we
# keep backups of all the files we will need to undo the current transaction.
#
# args:
#     undoId      optional Id - if not provided one will be generated
#     eventDesc   brief description of this undo transaction
#
# returns:
#     prints undoId on stdout
function undo_stack_id {
	local undoId="$1"
	local eventDesc="$2"
	[ -z "$eventDesc" ] && eventDesc="no description"
	if [ "$undoId" == latest ]; then
		undoId=`(cd $codestreamRoot/.undo && /bin/ls |tail -1)`
	elif [ -z "$undoId" ]; then
		undoId=`date '+%Y-%m-%d_%H-%M-%S'`
	fi
	[ ! -d $codestreamRoot/.undo/$undoId ] && mkdir -p $codestreamRoot/.undo/$undoId
	echo "$eventDesc" >$codestreamRoot/.undo/$undoId/description
	echo $undoId
}

function print_undo_stack {
	[ ! -d $codestreamRoot/.undo ] && echo "the undo stack is empty" >&2 && return
	for u in `ls $codestreamRoot/.undo`; do
		echo "  $u   `cat $codestreamRoot/.undo/$u/description`"
	done
}

# backup the contents of the $codestreamRoot directory tree into the undo stack
function backup_dot_codestream {
	local undoId="$1"
	[ -z "$undoId" ] && undoId=$(undo_stack_id "" "called backup_dot_codestream()")
	tar -C $codestreamRoot -czpf $codestreamRoot/.undo/$undoId/dot.codestream.tgz  --exclude='backups*' --exclude='.undo*' --exclude='log-capture*' .
}

function backup_mongo {
	local host="$1"
	local undoId="$2"
	[ ! -d $codestreamRoot/backups ] && mkdir $codestreamRoot/backups
	local filename="dump_$(date '+%Y-%m-%d_%H-%M-%S').gz"
	# echo "docker run --rm mongo:$mongoDockerVersion mongodump --host $host --archive --gzip"
	# docker run --rm mongo:$mongoDockerVersion mongodump --host $host --archive --gzip | cat > $codestreamRoot/backups/$filename
	docker run --rm --network=host mongo:$mongoDockerVersion mongodump --host localhost --archive --gzip | cat > $codestreamRoot/backups/$filename
	[ $? -ne 0 -o \( ! -s $codestreamRoot/backups/$filename \) ] && echo "backup failed" >&2 && return 1
	echo "Backed up $host to $codestreamRoot/backups/$filename"
	return 0
}

function restore_mongo {
	local host=$1 file=$2 prompt=$3
	[ -z "$file" ] && echo "usage: $0 --restore { latest | /path/to/dumpfile }" >&2 && return 1
	[ ! -f "$file" ] && echo "$file not found" >&2 && return 1
	echo "Restoring data from $file"
	echo -e "
  ***  WARNING   WARNING   WARNING  ***

  This will overwrite the data currently in mongo and replace it with the
  data from the backup file. The data currently in mongo will be lost!!
"
	if [ "$prompt" != no ]; then
		yesno "Do you want to proceed (y/N)? "
		[ $? -eq 0 ] && echo "never mind" && return 1
	fi
	# cat $file | docker run --rm -i mongo:$mongoDockerVersion mongorestore --host $host --archive --gzip --drop
	cat $file | docker run --rm -i --network=host mongo:$mongoDockerVersion mongorestore --host localhost --archive --gzip --drop
	[ $? -ne 0 ] && echo "error restoring data!!" >&2 && return 1
	return 0
}

function run_python_script {
	# this reports results to stdout so redirect other msgs to stderr
	[ $debugMode -eq 1 ] && echo "docker run --rm  --network=host -v $codestreamRoot:/cs $pythonRepo:$dtPython3DockerVersion $*" >&2
	docker run --rm  --network=host -v $codestreamRoot:/cs $pythonRepo:$dtPython3DockerVersion $*
}

# determine a container's state and report it on stdout
function container_state {
	local container=$1
	docker inspect --format='{{.State.Status}}' $container  2>/dev/null|grep -v '^[[:blank:]]*$'
}

# use a mongo container to run a json script using the mongo CLI
function repair_db {
	# this will execute scripts containing mongodb commands
	local fixScript=$1
	[ -z "$fixScript" ] && echo "name of fix script is required" && return 1
	fixScript=$(basename $fixScript)
	[ ! -f $codestreamRoot/$fixScript ] && echo "$codestreamRoot/$fixScript not found" >&2 && return 1
	docker run --rm --network=host -v $codestreamRoot:/cs mongo:$mongoDockerVersion mongo mongodb://localhost/codestream /cs/$fixScript && echo "repair script ran successfully" || { echo "repair script indicated failure"; return 1; }
	return 0
}

# start up a container regardless if it already exists
function run_or_start_container {
	local container=$1
	local state=$(container_state $container)
	[ "$state" == "running" ] && echo "Container $container is already running" >&2 && return
	if [ "$state" == "exited" ]; then
		# echo "docker start $container"
		docker start $container
		return
	fi
	[ -n "$state" ] && echo "Container $container is in an unknown state ($state). Aborting" >&2 && return
	echo "running container $container (docker run)"
	case $container in
	csmongo)
		echo docker run -d -P --network="host" --name csmongo --mount 'type=volume,source=csmongodata,target=/data' mongo:$mongoDockerVersion
		docker run -d -P --network="host" --name csmongo --mount 'type=volume,source=csmongodata,target=/data' mongo:$mongoDockerVersion;;
	csrabbitmq)
		echo docker run -d -P --network="host" --name csrabbitmq $rabbitmqRepo:$rabbitDockerVersion
		docker run -d -P --network="host" --name csrabbitmq $rabbitmqRepo:$rabbitDockerVersion;;
	csbcast)
		echo docker run -d -P -v $codestreamRoot:/opt/config --network="host" --name csbcast $broadcasterRepo:$broadcasterDockerVersion
		docker run -d -P -v $codestreamRoot:/opt/config --network="host" --name csbcast $broadcasterRepo:$broadcasterDockerVersion;;
	csapi)
		echo docker run -d -P -v $codestreamRoot:/opt/config --network="host" --name csapi $apiRepo:$apiDockerVersion
		docker run -d -P -v $codestreamRoot:/opt/config --network="host" --name csapi $apiRepo:$apiDockerVersion;;
	csmailout)
		echo docker run -d -P -v $codestreamRoot:/opt/config --network="host" --name csmailout $mailoutRepo:$mailoutDockerVersion
		docker run -d -P -v $codestreamRoot:/opt/config --network="host" --name csmailout $mailoutRepo:$mailoutDockerVersion;;
	*)
		echo "don't know how to start container $container" >&2
		return;;
	esac
}

# high-level routine to startup all containers
function start_containers {
	local runMongoFlag=$1
	[ -z "$runMongoFlag" ] && runMongoFlag=$runMongo
	if [ $runMongoFlag -eq 1 ]; then
		run_or_start_container csmongo
		sleep 5
	fi
	echo "Starting containuers..."
	run_or_start_container csrabbitmq
	sleep 7
	run_or_start_container csbcast
	sleep 3
	run_or_start_container csapi
	run_or_start_container csmailout
}

function stop_containers {
	local runMongoFlag=$1
	local c
	local state
	[ -z "$runMongoFlag" ] && runMongoFlag=$runMongo
	local containers="csapi csmailout csbcast csrabbitmq"
	[ $runMongoFlag -eq 1 ] && containers="$containers csmongo"
	echo "Stopping containers..."
	for c in $containers
	do
		state=$(container_state $c)
		# echo "container $c state: $state"
		if [ "$state" == "running" ]; then
			docker stop $c
		elif [ "$state" == "exited" ]; then
			echo "container $c is not running "
		elif [ -z "$state" ]; then
			echo "container $c not found - nothing to stop"
		else
			echo "container $c is in an unknown state ($state)"
		fi
	done
}

function remove_containers {
	local runMongoFlag=$1
	[ -z "$runMongoFlag" ] && runMongoFlag=$runMongo
	# echo docker rm csapi csmailout csbcast csrabbitmq
	# docker rm csapi csmailout csbcast csrabbitmq
	local containers="csapi csmailout csbcast csrabbitmq"
	[ $runMongoFlag -eq 1 ] && containers="$containers csmongo"
	echo "Removing containers..."
	for c in $containers
	do
		state=$(container_state $c)
		# echo "state of $c is $state"
		if [ "$state" == "exited" ]; then
			# echo "docker rm $c"
			docker rm $c
		elif [ -z "$state" ]; then
			echo "container $c not found - nothing to remove"
		else
			echo "container $c is in an unexpected state ($state)"
		fi
	done
	# [ $runMongoFlag -eq 1 ] && echo "docker rm csmongo" && docker rm csmongo
}

# report container and volume status
function docker_status {
	docker ps -a|egrep -e '[[:blank:]]cs|NAME'
	echo
	docker volume ls -f name=csmongodata
}

# create a custom MS Teams App Package for side-loading into MST
function create_mst_app_pkg {
	local appId=$1
	local publicHostName=$2
	zipCmd=`which zip`
	[ -z "$zipCmd" ] && echo "'zip' is needed to create an MST app package. It was not found in your search path" && return 1
	[ -z "$publicHostName" ] && echo "usage: `basename $0` --create-mst-app-pkg {appId} {public-api-hostname}" && return 1
	local tmpDir="$codestreamRoot/tmp$$"
	mkdir $tmpDir || { echo "mkdir $tmpDir failed"; return 1; }
	curl -s https://assets.codestream.com/mstbot/template/manifest.json.onprem -o $tmpDir/manifest.json.onprem || { echo "failed to get manifest template"; return 1; }
	curl -s https://assets.codestream.com/mstbot/template/outline.png -o $tmpDir/outline.png || { echo "failed to get outline.png"; return 1; }
	curl -s https://assets.codestream.com/mstbot/template/color.png -o $tmpDir/color.png || { echo "failed to get color.png"; return 1; }
	cat $tmpDir/manifest.json.onprem | sed -e "s/{{botId}}/$appId/g" | sed -e "s/{{publicApiFullyQualifiedHostName}}/$publicHostName/g" > $tmpDir/manifest.json || { echo "could not expand manifest template"; return 1; }
	(cd $tmpDir && $zipCmd -q $codestreamRoot/codestream-mst-app.zip manifest.json outline.png color.png) || { echo "failed to create zip file"; return 1; }
	ls -l $codestreamRoot/codestream-mst-app.zip
	/bin/rm -rf $tmpDir
	return 0
}

function load_config_cache {
	FQHN=$1  # global on purpose!
	[ -f $codestreamRoot/config-cache ] && . $codestreamRoot/config-cache
	[ -z "$FQHN" ] && FQHN=`hostname` && echo "using $FQHN for fully qualified host name"
	[ -z "$mailDomain" ] && mailDomain=`echo $FQHN|cut -d. -f 2-`
	[ -z "$SECRET_AUTH" ] && SECRET_AUTH=$(random_string)
	[ -z "$SECRET_COOKIE" ] && SECRET_COOKIE=$(random_string)
	[ -z "$SECRET_CONFIRMATION_CHEAT" ] && SECRET_CONFIRMATION_CHEAT=$(random_string)
	[ -z "$SECRET_SUBSCRIPTION_CHEAT" ] && SECRET_SUBSCRIPTION_CHEAT=$(random_string)
	[ -z "$SECRET_MAIL" ] && SECRET_MAIL=$(random_string)
	[ -z "$SECRET_BROADCAST_API" ] && SECRET_BROADCAST_API=$(random_string)
	[ -z "$SECRET_BROADCAST_AUTH" ] && SECRET_BROADCAST_AUTH=$(random_string)
	[ -z "$SENDER_EMAIL" ] && SENDER_EMAIL="codestream_alerts@$mailDomain"
	[ -z "$SUPPORT_EMAIL" ] && SUPPORT_EMAIL="codestream_support@$mailDomain"
}

function save_config_cache {
	echo -n "FQHN=$FQHN
SSL_CERT_FILE=$SSL_CERT_FILE
SSL_KEY_FILE=$SSL_KEY_FILE
SSL_CA_FILE=$SSL_CA_FILE
SECRET_AUTH=$SECRET_AUTH
SECRET_COOKIE=$SECRET_COOKIE
SECRET_CONFIRMATION_CHEAT=$SECRET_CONFIRMATION_CHEAT
SECRET_SUBSCRIPTION_CHEAT=$SECRET_SUBSCRIPTION_CHEAT
SECRET_MAIL=$SECRET_MAIL
SECRET_BROADCAST_API=$SECRET_BROADCAST_API
SECRET_BROADCAST_AUTH=$SECRET_BROADCAST_AUTH
SENDER_EMAIL=$SENDER_EMAIL
SUPPORT_EMAIL=$SUPPORT_EMAIL
" > $codestreamRoot/config-cache
}

function print_config_vars {
	echo "

Current configuration values:

	Fully qualified host name:       $FQHN
	SSL certificate file name:       $SSL_CERT_FILE
	SSL key file name:               $SSL_KEY_FILE
	SSL CA bundle file name:         $SSL_CA_FILE
	Email sender address:            $SENDER_EMAIL
	Support email address:           $SUPPORT_EMAIL

"
	# Auth secret:                     $SECRET_AUTH
	# Cookie secret:                   $SECRET_COOKIE
	# Confirmation secret:             $SECRET_CONFIRMATION_CHEAT
	# Subscription secret:             $SECRET_SUBSCRIPTION_CHEAT
	# Mail secret:                     $SECRET_MAIL
	# Broadcast API secret:            $SECRET_BROADCAST_API
	# Broadcast auth secret:           $SECRET_BROADCAST_AUTH
}

function edit_config_vars {
	local newVal
	echo -n "Fully qualified host name ($FQHN): "; read newVal; [ -n "$newVal" ] && FQHN=$newVal
	echo -n "SSL certificate file name ($SSL_CERT_FILE): "; read newVal; [ -n "$newVal" ] && SSL_CERT_FILE=$newVal
	echo -n "SSL key file name ($SSL_KEY_FILE): "; read newVal; [ -n "$newVal" ] && SSL_KEY_FILE=$newVal
	echo -n "SSL CA bundle file name ($SSL_CA_FILE): "; read newVal; [ -n "$newVal" ] && SSL_CA_FILE=$newVal
	# echo -n "Auth secret ($SECRET_AUTH): "; read newVal; [ -n "$newVal" ] && SECRET_AUTH=$newVal
	# echo -n "Cookie secret ($SECRET_COOKIE): "; read newVal; [ -n "$newVal" ] && SECRET_COOKIE=$newVal
	# echo -n "Confirmation secret ($SECRET_CONFIRMATION_CHEAT): "; read newVal; [ -n "$newVal" ] && SECRET_CONFIRMATION_CHEAT=$newVal
	# echo -n "Subscription secret ($SECRET_SUBSCRIPTION_CHEAT): "; read newVal; [ -n "$newVal" ] && SECRET_SUBSCRIPTION_CHEAT=$newVal
	# echo -n "Mail secret ($SECRET_MAIL): "; read newVal; [ -n "$newVal" ] && SECRET_MAIL=$newVal
	# echo -n "Broadcast API secret ($SECRET_BROADCAST_API): "; read newVal; [ -n "$newVal" ] && SECRET_BROADCAST_API=$newVal
	# echo -n "Broadcast auth secret ($SECRET_BROADCAST_AUTH): "; read newVal; [ -n "$newVal" ] && SECRET_BROADCAST_AUTH=$newVal
	echo -n "Email sender address ($SENDER_EMAIL): "; read newVal; [ -n "$newVal" ] && SENDER_EMAIL=$newVal
	echo -n "Support sender address ($SUPPORT_EMAIL): "; read newVal; [ -n "$newVal" ] && SUPPORT_EMAIL=$newVal
}

function validate_config_vars {
	local error=0
	[ -z "$SSL_CERT_FILE" ] && echo "SSL certificate file name required" && error=1
	[ -n "$SSL_CERT_FILE" -a ! -f $codestreamRoot/$SSL_CERT_FILE ] && echo "SSL certificate $codestreamRoot/$SSL_CERT_FILE not found" && error=1
	[ -z "$SSL_KEY_FILE" ] && echo "SSL key file name required" && error=1
	[ -n "$SSL_KEY_FILE" -a ! -f $codestreamRoot/$SSL_KEY_FILE ] && echo "SSL key file $codestreamRoot/$SSL_KEY_FILE not found" && error=1
	[ -z "$SSL_CA_FILE" ] && echo "SSL CA bundle file name required" && error=1
	[ -n "$SSL_CA_FILE" -a ! -f $codestreamRoot/$SSL_CA_FILE ] && echo "SSL CA bundle file $codestreamRoot/$SSL_CA_FILE not found" && error=1
	return $error
}

function create_config_from_template {
	local cfg_file=$1 cfg_template=$2
	cat $cfg_template \
	| sed -e "s/{{FQHN}}/$FQHN/g" \
	| sed -e "s/{{SSL_CERT_FILE}}/$SSL_CERT_FILE/g" \
	| sed -e "s/{{SSL_KEY_FILE}}/$SSL_KEY_FILE/g" \
	| sed -e "s/{{SSL_CA_FILE}}/$SSL_CA_FILE/g" \
	| sed -e "s/{{SENDER_EMAIL}}/$SENDER_EMAIL/g" \
	| sed -e "s/{{SUPPORT_EMAIL}}/$SUPPORT_EMAIL/g" \
	| sed -e "s/{{SECRET_AUTH}}/$SECRET_AUTH/g" \
	| sed -e "s/{{SECRET_COOKIE}}/$SECRET_COOKIE/g" \
	| sed -e "s/{{SECRET_CONFIRMATION_CHEAT}}/$SECRET_CONFIRMATION_CHEAT/g" \
	| sed -e "s/{{SECRET_SUBSCRIPTION_CHEAT}}/$SECRET_SUBSCRIPTION_CHEAT/g" \
	| sed -e "s/{{SECRET_MAIL}}/$SECRET_MAIL/g" \
	| sed -e "s/{{SECRET_BROADCAST_API}}/$SECRET_BROADCAST_API/g" \
	| sed -e "s/{{SECRET_BROADCAST_AUTH}}/$SECRET_BROADCAST_AUTH/g" \
	> $cfg_file
}

function capture_logs {
	local since=$1
	[ -z "$since" ] && echo "bad usage: missing hours or minutes spec" && exit 1
	[ ! -d $codestreamRoot/log-capture ] && mkdir $codestreamRoot/log-capture
	local logdir=cslogs$$
	local now=`date +%Y%m%d-%H%M%S`
	tmpDir=$HOME/$logdir
	mkdir $tmpDir
	docker logs --since $since csapi >$tmpDir/api.log 2>&1
	docker logs --since $since csbcast >$tmpDir/broadcaster.log 2>&1
	docker logs --since $since csrabbitmq >$tmpDir/rabbitmq.log 2>&1
	docker logs --since $since csmailout >$tmpDir/mailout.log 2>&1
	tar -czpf $codestreamRoot/log-capture/codestream-onprem-logs.$now.tgz -C $HOME $logdir
	[ -d "$tmpDir" ] && /bin/rm -rf $tmpDir
	ls -l $codestreamRoot/log-capture/codestream-onprem-logs.$now.tgz
}

# display our terms of service and require user to agree.
# returns 0 if they do agree, 1 otherwise
function accept_tos {
	[ -f $codestreamRoot/.tos-agreed ] && return 0
	local ans
	echo -n "
Before proceeding with the installation, you will need to accept our
Terms of Service. Use the space-bar, 'b' (for back) or arrow keys to
move through the pager to read the terms. Press 'q' when you're done.

You'll then need agree to the terms to continue with the installation.

Press ENTER to read our Terms of Service..."
	read ans
	curl https://raw.githubusercontent.com/TeamCodeStream/onprem-install/$installBranch/docs/src/assets/terms.txt -s -o $codestreamRoot/terms.txt
	[ $? -ne 0 ] && echo "Could not locate the terms of service!" && exit 1
	less $codestreamRoot/terms.txt
	echo -n "

If you agree to these terms, please type 'i agree': "
	read ans
	ans=`echo $ans | $TR_CMD [:upper:] [:lower:]`
	[ "$ans" == "i agree" ] && touch $codestreamRoot/.tos-agreed && return 0
	return 1
}

function quickstart {
	local start=1
	local _fqhn
	while [ $# -gt 0 ]
	do
		case $1 in
		--fqhn) _fqhn=$2; shift 2;;
		--config-only) start=0; shift;;
		*) echo "`basename $0` --quickstart [--config-only] [--fqhn hostname]"; exit 1;;
		esac
	done
	[ -z "$_fqhn" ] && _fqhn=`hostname` && echo "using $_fqhn for fully-qualified host name"
	if [ ! -d $codestreamRoot ]; then
		echo "creating $codestreamRoot" && mkdir $codestreamRoot && cp -p $0 $codestreamRoot || { echo failed to create $codestreamRoot directory; exit 1; }
	fi
	[ ! -f $codestreamRoot/single-host-preview-cfg.json.template ] && get_config_file_template "" quickstart
	load_config_cache $_fqhn
	save_config_cache
	create_config_from_template $codestreamRoot/codestream-services-config.json $codestreamRoot/single-host-preview-cfg.json.template
	[ $start -eq 1 ] && $0 -a start
}

function install_and_configure {
	local answerYes=$1
	echo "ANSWERYES=$answerYes"

	[ -f $codestreamRoot/codestream-services-config.json ] && echo "$codestreamRoot/codestream-services-config.json already exists!">&2 && exit 1

	echo -n "
This script will install the single-host-preview version of CodeStream OnPrem.
It runs services in docker containers on a single host.

You will need to perform some external work and update the codestream config file
before any of the services can be launched.

This script will walk you through all that.  On this host, the only modifications
made will be the creation of a $codestreamRoot/ directory and a number of config
files placed in it.  Everything else will be inside of docker containers and/or
docker volumes.

Press ENTER when you are ready to proceed..."
	[ $answerYes -ne 1 ] && read

	if [ ! -d $codestreamRoot ]; then
		echo "creating $codestreamRoot" && mkdir $codestreamRoot && cp -p $0 $codestreamRoot || { echo "failed to create $codestreamRoot directory"; exit 1; }
	fi
	[ ! -f $codestreamRoot/single-host-preview-cfg.json.template ] && get_config_file_template "" minimal

	echo
	echo
	echo "Copy your 3 SSL certificate files (cert, key and CA bundle) to $codestreamRoot/".
	echo
	echo -n "When you've done so, press ENTER to continue..."
	[ $answerYes -ne 1 ] && read || echo

	load_config_cache
	doLoop=1
	while [ $doLoop -eq 1 ]
	do
		[ $answerYes -ne 1 ] && { edit_config_vars; echo; }
		validate_config_vars
		if [ $? -eq 0 ]; then
			print_config_vars
			if [ $answerYes -ne 1 ]; then
				yesno "Are these values ok (y/n)? "
				[ $? -eq 1 ] && doLoop=0
			else
				doLoop=0
			fi
		else
			[ $answerYes -eq 1 ] && echo "vars invalid and not in interactive mode. Bye" >&2 && exit 1
			echo
		fi
	done
	save_config_cache
	create_config_from_template $codestreamRoot/codestream-services-config.json $codestreamRoot/single-host-preview-cfg.json.template
	echo "

Your basic config file ($codestreamRoot/codestream-services-config.json) is ready.
Continue with the installation instructions. At a minimum, you will need to edit
the SMTP settings in the config file before you start the docker services.

"
}


#########
#########  Execution Starts Here
#########

### ------ Globals ------
[ -z "$codestreamRoot" ] && codestreamRoot=`/bin/bash -c 'echo ~/.codestream'`
[ -z "$TR_CMD" ] && TR_CMD=tr
releaseSufx=""
releasePath=""
installBranch=""
logCapture=""
[ -f $codestreamRoot/debug.on ] && debugMode=1 || debugMode=0

# The release file determines which docker repos and image versions we use (beta, pre-release or GA (null string))
[ -f $codestreamRoot/release ] && { releaseSufx=".`cat $codestreamRoot/release`"; releasePath="/`cat $codestreamRoot/release`"; echo "Running $releaseSufx release of CodeStream" >&2; }

# installation-branch determines which branch of onprem-install to use when downloading files (master or beta)
[ -f $codestreamRoot/installation-branch ] && { installBranch="`cat $codestreamRoot/installation-branch`"; echo "Installation branch is $installBranch" >&2; } || installBranch="master"

# The url (or base url) of the file containing version information for this release
versionUrl="https://raw.githubusercontent.com/TeamCodeStream/onprem-install/$installBranch/versions/preview-single-host.ver"
[ -f $codestreamRoot/config-cache ] && . $codestreamRoot/config-cache

### ------ Checkout this host system for compatibility
check_env || exit 1

### ------ Migration to new 'codestream' script
if [ `basename $0` == single-host-preview-install.sh ]; then
	echo "single-host-preview-install.sh has been replaced with a new control script."
	[ ! -f $codestreamRoot/codestream ] && echo "Downloading $codestreamRoot/codestream."
	echo -e "\nPlease run '$codestreamRoot/codestream' from now on."
	[ ! -f $codestreamRoot/codestream ] && update_myself
	exit 0
fi

### ------ Start parsing command line options
[ "$1" == "--help" -o -z "$1" ] && usage help
[ "$1" == "--quickstart" ] && { shift && accept_tos && quickstart "$@"; exit $?; }
[ "$1" == "--update-myself" ] && update_myself
[ "$1" == "--undo-stack" ] && { print_undo_stack; exit $?; }

migrate_config_file_template     # the downloaded config template is now 'single-host-preview-cfg.json.template'
# migrate_control_script           # the control script is now 'codestream'

[ "$1" == "--apply-support-pkg" ] && shift && { apply_support_package "$@"; exit $?; }
[ "$1" == "--create-mst-app-pkg" ] && shift && { create_mst_app_pkg "$@"; exit $?; }

fetch_utilities
load_container_versions

[ "$1" == "--run-python-script" ] && { shift; run_python_script "$@"; exit $?; }
[ "$1" == "--run-support-script" ] && { run_support_script "$2"; exit $?; }
[ "$1" == "--run-api-utility" ] && shift && { run_api_utility "$@"; exit $?; }
[ "$1" == "--repair-db" ] && { repair_db "$2"; exit $?; }
[ "$1" == "--update-containers" ] && shift && { update_containers_except_mongo $*; exit $?; }
[ "$1" == "--logs" ] && { capture_logs "$2"; exit $?; }
[ "$1" == "--backup" ] && { backup_mongo $FQHN; exit $?; }
if [ "$1" == "--full-backup" ]; then
	{ backup_mongo $FQHN && d=`/bin/ls -tr $codestreamRoot/backups|tail -1|cut -f1 -d.|sed -e 's/dump_//'` && tar czpf ~/full-codestream-backup.$d.tgz $codestreamRoot && echo -e "\nFull backup is here:" && /bin/ls -l ~/full-codestream-backup.$d.tgz || exit 1; }
	exit 0
fi

if [ "$1" == "--restore" ]; then
	[ "$2" == latest ] && { restore_mongo $FQHN "$(/bin/ls $codestreamRoot/backups/dump_*.gz | tail -1)"; exit $?; }
	restore_mongo $FQHN $2
	exit $?
fi

[ "$CS_MONGO_CONTAINER" == "ignore" ] && runMongo=0 || runMongo=1
answerYes=0
action=""
[ "$1" == "--start" ] && shift && action=start
[ "$1" == "--stop" ] && shift && action=stop
[ "$1" == "--restart" ] && shift && action=restart
[ "$1" == "--reset" ] && shift && action=reset
[ "$1" == "--status" ] && shift && action=status
[ "$1" == "--stop-execpt-mongo" ] && shift && action=stop && runMongo=0
[ "$1" == "--reset-execpt-mongo" ] && shift && action=reset && runMongo=0

while getopts "ya:M" arg
do
	case $arg in
		y) answerYes=1;;
		M) runMongo=0;;
		a) action=$OPTARG;;
		*) usage;;
	esac
done
shift `expr $OPTIND - 1`
[ -z "`echo $action | egrep -e '^(install|start|start_mongo|stop|restart|reset|status)$'`" ] && echo "bad action" && usage


[ $runMongo -eq 0 ] && echo "Mongo container will not be touched (CS_MONGO_CONTAINER=ignore)"

case $action in
	install)
		# this installation is deprecated. Use --quickstart
		accept_tos || { echo "CodeStream won't be installed."; exit 1; }
		install_and_configure $answerYes;;
	reset)
		echo "Stopping and removing codestream containers..."; stop_containers; remove_containers;;
	start)
		start_containers; sleep 1; docker_status;;
	start_mongo)
		run_or_start_container csmongo; sleep 2; docker_status;;
	status)
		docker_status;;
	stop)
		stop_containers;;
	restart)
		stop_containers; sleep 1; start_containers; sleep 1; docker_status;;
	*)
		usage;;
esac
exit 0
