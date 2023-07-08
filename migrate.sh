#!/usr/bin/env bash

# Exit on error
set -e

detect_runtime() {
	# Check for docker or podman
	for cmd in "podman" "docker"; do
		if $cmd >/dev/null 2>&1; then
			RUNTIME_CMD=$cmd
			break
		fi
	done

	if [[ -z "${RUNTIME_CMD}" ]]; then
		echo >&2 "ERROR: Could not find a container runtime. Did you install Docker?"
		echo >&2 "Please click on your server distribution in the list here, then follow the installation instructions:"
		echo >&2 "     https://docs.docker.com/engine/install/#server"
		exit 1
	fi

	# Check for docker compose or podman compose
	if [[ "${RUNTIME_CMD}" == "podman" ]]; then
		echo "WARNING: podman will probably work, but I haven't tested it much. It's up to you to make sure all the permissions for podman are correct!"
		COMPOSE_CMD="podman-compose"
		if $COMPOSE_CMD >/dev/null 2>&1; then
			COMPOSE_FOUND="true"
		else
			echo >&2 "ERROR: podman detected, but podman-compose is not installed. Please install podman-compose!"
			exit 1
		fi
	else
		for cmd in "docker compose" "docker-compose"; do
			COMPOSE_CMD="${cmd}"
			if $COMPOSE_CMD >/dev/null 2>&1; then
				COMPOSE_FOUND="true"
				break
			fi
		done
	fi

	if [[ "${COMPOSE_FOUND}" != "true" ]]; then
		echo >&2 "ERROR: Could not find Docker Compose. Is Docker Compose installed?"
		echo >&2 "Please click on your server distribution in the list here, then follow the installation instructions:"
		echo >&2 "     https://docs.docker.com/engine/install/#server"
		exit 1
	fi

	# Grab the runtime versions:
	DOCKER_VERSION="$($RUNTIME_CMD --version | head -n 1)"
	DOCKER_MAJOR="$(echo ${DOCKER_VERSION#*version } | cut -d '.' -f 1 | tr -cd '[:digit:]')"
	COMPOSE_VERSION="$($COMPOSE_CMD version | head -n 1)"
	COMPOSE_MAJOR="$(echo ${COMPOSE_VERSION#*version } | cut -d '.' -f 1 | tr -cd '[:digit:]')"

	# Get the compose version string we can use for labels
	COMPOSE_LABEL_VERSION="$(echo ${COMPOSE_VERSION} | sed 's/.*\(version\)/\1/' | cut -d' ' -f2 | tr -d ',')"

	echo "Detected runtime: $RUNTIME_CMD (${DOCKER_VERSION})"
	echo "Detected compose: $COMPOSE_CMD (${COMPOSE_VERSION})"

	RUNTIME_STATE="ERROR"
	if docker run --rm -v "$(pwd):/host:ro" hello-world >/dev/null 2>&1; then
		RUNTIME_STATE="OK"
	fi
	echo "   Runtime state: $RUNTIME_STATE"
	echo ""

	# Warn if using an unsupported Docker version
	if ((DOCKER_MAJOR < 20)); then
		echo "-----------------------------------------------------------------------"
		echo "WARNING: Your version of Docker is outdated and unsupported."
		echo ""
		echo "Only Docker Engine versions 20 and up are supported by Docker Inc:"
		echo "    https://endoflife.date/docker-engine"
		echo ""
		echo "This data migration may still work, but if you run into issues,"
		echo "please install the official version of Docker before filing an issue:"
		echo "    https://docs.docker.com/engine/install/"
		echo ""
		echo "-----------------------------------------------------------------------"
	fi
}

display_help() {
	echo "Usage:"
	echo "  $0 import [import options]"
	echo "  $0 export [export options]"
	echo ""
	echo "Import Options:"
	echo "  --from-dir path/to/directory"
	echo "  --from-tar-gz path/to/archive.tar.gz"
	echo "  --from-volume [Docker volume name]"
	echo "  --to-led-volume [LED volume name]*"
	echo ""
	echo "Export Options:"
	echo "  --from-led-volume [LED volume name]*"
	echo "  --to-tar-gz path/to/archive.tar.gz"
	echo "  --to-volume [Docker volume name]"
	echo ""
	echo "*Lemmy-Easy-Deploy Volume Names"
	echo "  This script expects the name of a volume as it appears in docker-compose.yml"
	echo "  In other words, *without* the lemmy-easy-deploy_ prefix."
	echo "  Examples:"
	echo "    caddy_data"
	echo "    caddy_config"
	echo "    pictrs_data"
	echo "    postgres_data"
	echo "    postfix_data"
	echo "    postfix_mail"
	echo "    postfix_spool"
	echo "    postfix_keys"

}

# Create an empty volume in the Lemmy-Easy-Deploy project
create_led_volume() {
	echo "--> Creating destination volume..."
	docker volume create --name "lemmy-easy-deploy_${1:?}" --label "com.docker.compose.project=lemmy-easy-deploy" --label "com.docker.compose.version=${COMPOSE_LABEL_VERSION:?}" --label "com.docker.compose.volume=${1:?}" --label "lemmy-easy-deploy.import.type=${2:?}"
}

create_plain_volume() {
	echo "--> Creating destination volume..."
	docker volume create --name "${1:?}"
}

# Import from a directory on the filesystem
dir_import() {
	DIR_REAL_PATH="$(realpath ${FROM_DIR:?})"
	echo "--> Importing from directory: ${DIR_REAL_PATH:?}"
	echo "--> Importing to: lemmy-easy-deploy_${TO_LED_VOLUME:?}"
	create_led_volume "${TO_LED_VOLUME:?}" "directory"
	docker run --rm -v ${DIR_REAL_PATH:?}:/from:ro -v lemmy-easy-deploy_${TO_LED_VOLUME:?}:/to alpine ash -c 'cd /from ; cp -av . /to'
	echo "--> SUCCESS: Import complete."
}

# Import from the contents of a .tar.gz
tar_import() {
	TAR_GZ_REAL_PATH="$(realpath ${FROM_TAR_GZ:?})"
	echo "--> Importing from archive: ${TAR_GZ_REAL_PATH:?}"
	echo "--> Importing to: lemmy-easy-deploy_${TO_LED_VOLUME:?}"
	create_led_volume "${TO_LED_VOLUME:?}" "tar"
	docker run --rm -v ${TAR_GZ_REAL_PATH:?}:/from.tar.gz:ro -v lemmy-easy-deploy_${TO_LED_VOLUME:?}:/to alpine ash -c 'tar -xzvf /from.tar.gz -C /to'
	echo "--> SUCCESS: Import complete."
}

# Import from an existing volume
volume_import() {
	echo "--> Importing from Docker volume: ${FROM_VOLUME:?}"
	echo "--> Importing to: lemmy-easy-deploy_${TO_LED_VOLUME:?}"
	create_led_volume "${TO_LED_VOLUME:?}" "volume"
	docker run --rm -v ${FROM_VOLUME:?}:/from:ro -v lemmy-easy-deploy_${TO_LED_VOLUME:?}:/to alpine ash -c 'cd /from ; cp -av . /to'
	echo "--> SUCCESS: Import complete."
}

# Export to a tar.gz
tar_export() {
	echo "--> Exporting from Docker volume: lemmy-easy-deploy_${FROM_LED_VOLUME:?}"
	echo "--> Exporting to archive: ${TO_TAR_GZ:?}"
	docker run --rm -v lemmy-easy-deploy_${FROM_LED_VOLUME:?}:/from:ro alpine ash -c 'tar -czvf - -C /from .' >${TO_TAR_GZ:?}
	echo "--> SUCCESS: Export complete."
}

# Export to a Docker volume
volume_export() {
	echo "--> Exporting from Docker volume: lemmy-easy-deploy_${FROM_LED_VOLUME:?}"
	echo "--> Exporting to Docker volume: ${TO_VOLUME:?}"
	docker run --rm -it -v lemmy-easy-deploy_${FROM_LED_VOLUME:?}:/from:ro -v ${TO_VOLUME:?}:/to alpine ash -c 'cd /from ; cp -av . /to'
	echo "--> SUCCESS: Export complete."
}

# If there are no arguments, show help
if [[ -z "$1" ]]; then
	display_help
	exit 0
fi

# parse arguments
while (("$#")); do
	case "$1" in
	import)
		OPERATION="import"
		shift 1
		;;
	export)
		OPERATION="export"
		shift 1
		;;
	-h | --help)
		display_help
		exit 0
		;;
	--from-dir)
		shift 1
		FROM_DIR="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--from-dir'"
			echo
			display_help
			exit 1
		}
		;;
	--from-tar-gz)
		shift 1
		FROM_TAR_GZ="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--from-tar-gz'"
			echo
			display_help
			exit 1
		}
		;;
	--from-volume)
		shift 1
		FROM_VOLUME="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--from-volume'"
			echo
			display_help
			exit 1
		}
		;;
	--to-led-volume)
		shift 1
		TO_LED_VOLUME="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--to-led-volume'"
			echo
			display_help
			exit 1
		}
		;;
	--from-led-volume)
		shift 1
		FROM_LED_VOLUME="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--from-led-volume'"
			echo
			display_help
			exit 1
		}
		;;
	--to-tar-gz)
		shift 1
		TO_TAR_GZ="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--to-tar-gz'"
			echo
			display_help
			exit 1
		}
		;;
	--to-volume)
		shift 1
		TO_VOLUME="$1"
		shift 1 || {
			echo >&2 "ERROR: Argument expected after '--to-volume'"
			echo
			display_help
			exit 1
		}
		;;
	*)
		echo >&2 "ERROR: Unrecognized argument: $1"
		echo
		display_help
		exit 1
		;;
	esac
done

# Check for invalid argument combinations
if [[ "${OPERATION}" == "import" ]]; then
	if [[ -n "${FROM_LED_VOLUME}" ]] || [[ -n "${TO_TAR_GZ}" ]] || [[ -n "${TO_VOLUME}" ]]; then
		echo >&2 "ERROR: Invalid options"
		echo
		display_help
		exit 1
	fi

	# These options are mutually exclusive, only let the user use one
	options=("FROM_DIR" "FROM_TAR_GZ" "FROM_VOLUME")
	IMPORT_ARG_COUNT=0
	for opt in "${options[@]}"; do
		value="${!opt}"

		if [[ -n "${value}" ]]; then
			if [[ "${IMPORT_ARG_COUNT}" != "1" ]]; then
				IMPORT_ARG_COUNT=1
			else
				echo >&2 "ERROR: Incompatible arguments"
				echo
				display_help
			fi
		fi
	done

	# We do need at least one, though
	if [[ "${IMPORT_ARG_COUNT}" == "0" ]]; then
		echo >&2 "ERROR: Missing a source to import from"
		echo >&2
		display_help
		exit 1
	fi

	# We need a destination
	if [[ -z "${TO_LED_VOLUME}" ]]; then
		echo >&2 "ERROR: Missing a Lemmy-Easy-Deploy volume name to import as"
		echo >&2
		display_help
		exit 1
	fi

	# The volume name can't start with lemmy-easy-deploy_
	if [[ "${TO_LED_VOLUME}" == "lemmy-easy-deploy_"* ]]; then
		echo >&2 "ERROR: The destination Lemmy-Easy-Deploy volume name cannot be prefixed with 'lemmy-easy-deploy_'"
		echo >&2 "    This prefix will be added automatically as needed. Try using:"
		echo >&2 "        --to-led-volume ${TO_LED_VOLUME#lemmy-easy-deploy_}"
		exit 1
	fi
fi

if [[ "${OPERATION}" == "export" ]]; then
	if [[ -n "${FROM_DIR}" ]] || [[ -n "${FROM_TAR_GZ}" ]] || [[ -n "${FROM_VOLUME}" ]] || [[ -n "${TO_LED_VOLUME}" ]]; then
		echo >&2 "ERROR: Invalid options"
		echo
		display_help
		exit 1
	fi

	# These options are mutually exclusive, only let the user use one
	options=("TO_TAR_GZ" "TO_VOLUME")
	EXPORT_ARG_COUNT=0
	for opt in "${options[@]}"; do
		value="${!opt}"

		if [[ -n "${value}" ]]; then
			if [[ "${EXPORT_ARG_COUNT}" != "1" ]]; then
				EXPORT_ARG_COUNT=1
			else
				echo >&2 "ERROR: Incompatible arguments"
				echo
				display_help
			fi
		fi
	done

	# We do need at least one, though
	if [[ "${EXPORT_ARG_COUNT}" == "0" ]]; then
		echo >&2 "ERROR: Missing a destination to export to"
		echo >&2
		display_help
		exit 1
	fi

	# The volume name can't start with lemmy-easy-deploy_
	if [[ "${FROM_LED_VOLUME}" == "lemmy-easy-deploy_"* ]]; then
		echo >&2 "ERROR: The source Lemmy-Easy-Deploy volume name cannot be prefixed with 'lemmy-easy-deploy_'"
		echo >&2 "    This prefix will be added automatically as needed. Try using:"
		echo >&2 "        --from-led-volume ${FROM_LED_VOLUME#lemmy-easy-deploy_}"
		exit 1
	fi
fi

# Detect the docker runtime
detect_runtime

# Run the operation
if [[ "${OPERATION}" == "import" ]]; then
	# Make sure the target volume does not exist already
	if $RUNTIME_CMD volume ls | grep -q " lemmy-easy-deploy_${TO_LED_VOLUME}$" 2>&1 >/dev/null; then
		echo >&2
		echo >&2 "The destination volume '${TO_LED_VOLUME}' in Docker Compose project 'lemmy-easy-deploy' already exists:"
		echo >&2 "          lemmy-easy-deploy_${TO_LED_VOLUME}"
		echo >&2
		echo >&2 "If you are 100% certain you no longer need this volume, delete it first, then try again."
		echo >&2
		exit 1
	fi

	echo "--> Operation: import"

	# Figure out where to import from
	if [[ -n "${FROM_DIR}" ]]; then
		dir_import
	elif [[ -n "${FROM_TAR_GZ}" ]]; then
		tar_import
	elif [[ -n "${FROM_VOLUME}" ]]; then
		volume_import
	fi

elif [[ "${OPERATION}" == "export" ]]; then
	# Make sure the target volume exists
	if ! $RUNTIME_CMD volume ls | grep -q " lemmy-easy-deploy_${FROM_LED_VOLUME}$" 2>&1 >/dev/null; then
		echo >&2
		echo >&2 "The source volume '${FROM_LED_VOLUME}' in Docker Compose project 'lemmy-easy-deploy' does not exist."
		exit 1
	fi

	echo "--> Operation: export"

	# Figure out where to export to
	if [[ -n "${TO_TAR_GZ}" ]]; then
		# Make sure it ends in tar.gz
		if [[ ! ${TO_TAR_GZ} =~ \.tar\.gz$ ]]; then
			echo >&2
			echo >&2 "ERROR: Destination archive '${TO_TAR_GZ}' does not end in .tar.gz"
			echo >&2
			exit 1
		fi

		# Make sure the destination tar doesn't already exist
		if [[ -f "${TO_TAR_GZ}" ]]; then
			echo >&2
			echo >&2 "ERROR: Destination archive '${TO_TAR_GZ}' already exists"
			echo >&2
			exit 1
		fi
		tar_export
	elif [[ -n "${TO_VOLUME}" ]]; then
		if $RUNTIME_CMD volume ls | grep -q " ${TO_VOLUME}$" 2>&1 >/dev/null; then
			echo >&2
			echo >&2 "ERROR: Destination Docker volume '${TO_VOLUME}' already exists"
			echo >&2
		fi
		volume_export
	fi
else
	display_help
	exit 0
fi
