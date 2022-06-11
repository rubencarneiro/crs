#!/bin/bash

_RESETCOLOR_=$(tput sgr0) # Reset the foreground color
_RED_=$(tput setaf 1)
_GREEN_=$(tput setaf 2)
_YELLOW_=$(tput setaf 3)

RegionNames="APAC, EU, ME, Mexico, NA, SA, Other, None"

RangeResult=()
ErrorFound=""
NumContainers=0
PersistencyDir=""
CRS_docker_image_file=""
CRS_docker_image_tag="crs:current"
Container_Timezone=""
CRS_eph_ports_reserv=""
JobsLevel="-1"
StorageFolders=()
CRS_provisioning_region=""
CRS_provisioning_password=""

HasParamR=false
HasParamI=false
HasParamF=false
HasParamJ=false
HasParamT=false
HasParamS=false
HasParamP=false
HasParamProvisioningRegion=false
HasParamProvisioningPassword=false
RunAsRoot=true
EnableCoreDump=false
EnableDebug=false
YesToAllQuestions=false

function PrintHelp
{
    echo "
 Usage:
     crs_dockers.sh COMMAND [OPTIONS]
 
 COMMAND:
     -C, --create        Load the Docker image from file, then create and run containers from it.
                         Options: -r, -i, -f, [-s]*, [-j], [-t], [-p], [--usermode], [--enable-core-dump], [--provisioning_region], [--provisioning_password]
 
     -X, --execute       Run containers (creates the missing ones from the latest installed CRS Docker image).
                         Options: -r, -f, [-s]*, [-j], [-t], [-p], [--usermode], [--enable-core-dump], [--provisioning_region], [--provisioning_password]
 
     -U, --update        Update CRS docker containers to the specified Docker image file.
                         Options: -r, -i, -f, [-s]*, [-j], [-t], [-p], [--usermode], [--enable-core-dump], [--provisioning_region], [--provisioning_password]
 
     -D, --delete        Delete docker containers. Only Docker container is removed. All CRS data (configuration,
                         DBs, licenses, logs) are persisted in the CRS data folder, creating a container with the
                         same index will reuse those data.
                         Options: -r, [--usermode], [-y]
 
     -L, --get_logs      Collect logs in crs<crsnum>_Logs.tar.gz files. The config folder is needed
                         to retrieve logs of non running containers. Files already present will be overwritten.
                         Options: -r, [-f], [--usermode]
 
     -S, --get_stats     Get information about the system and containers
                         Options: [-r], [--usermode]
 
     -H, -h, --help      Print help
 
 OPTIONS:
     -r, --range <VALUE>                    Range or sequence of CRS containers indexes (<VALUE> is in the form: 1,2,3,... or 1-3)
 
     -i, --image <IMAGE FILE>               The docker image to use for the containers
 
     -f, --crs_folder <PATH>                Path to the CRS data folder (configuration/storage_accounts/logs/db persistency)
 
     -j, --jobs <CORES>                     Resources assigned to the CRS container [2 ... cpu_cores]
 
     -t, --timezone <TZ_NAME>               Name of the timezone to be assigned to the CRS container (from /usr/share/zoneinfo, example US/Pacific)
 
     -s, --storage_folder <PATH>            Path of the storage folder as mounted in the host. This option can be used multiple times to assign more
                                            storages. IMPORTANT: each folder must be on a different partition, paths from a same partition cannot be used.
 
     -p, --ports <VALUE>                    Range or sequence of IP ephemeral ports that will be reserved reserve for CRS use (default: 44301-44399)

     -y, --yes                              Assume yes to all questions.

     --usermode                             Run the script with no root privileges. This is not the default, use this parameter carefully and consistently.

     --enable-core-dump                     Change OS settings to make CRS core dumps available (requires root privileges). Use this parameter carefully because on Ubuntu Apport will stop to collect sytem crashes.
     
     --debug                                Enable Docker debug mode (unsecure)
     
     --provisioning_region <REGION_NAME>    Name of the region to be used for provisioning (<REGION_NAME>: $RegionNames)

     --provisioning_password <PASSWORD>     Admin password to be used for provisioning (--provisioning_region option must be specified)
     
 Examples:
 
     ./crs_docker.sh -C -r 2-4 -f ./CRSdata -i docker_crs_VERSION.tar.gz -s /mnt/storage1 -s /mnt/storage2
         Load CRS Docker image from tar.gz and create 3 containers (crs2, crs3, crs4) sharing the two storages.
 
     ./crs_docker.sh -X -r 5 -f ./CRSdata -s /mnt/storage1
         Create 1 container (crs5) from a CRS Docker image already loaded.
 
     ./crs_docker -D -r 1,2,7
         Delete containers: crs1, crs2 and crs7. CRS data are persisted in the DATA folder.
 
     ./crs_docker -U -r 8 -i ./docker_crs_VERSION.tar.gz -f /home/username/CRSdata -s /mnt/storage1
         Update the container crs8 using the new image provided.
"
}

function CheckRangeValue
{
    Range=()
    if grep -q "," <<< "$1"; then
        for i in $(echo $1 | tr "," "\n"); do
            if [ -n "$i" ] && [ "$i" -eq "$i" ] 2>/dev/null; then
                Range+=($i)
            else
                ErrorFound="Only numbers in range"
                break;
            fi
        done
        Range=($(printf '%s\n' "${Range[@]}"|sort -u))
    elif grep -q "-" <<< "$1"; then
        for i in $(echo $1 | tr "-" "\n"); do
            if [ -n "$i" ] && [ "$i" -eq "$i" ] 2>/dev/null; then
                Range+=($i)
            else
                ErrorFound="Only numbers in range"
                break
            fi
        done
        if [ ${#Range[@]} -ne 2 ]; then
            ErrorFound="Only two elements in range type '-'"
        else
            Range=($(printf '%s\n' "${Range[@]}"|sort -u))
            if [ ${#Range[@]} -ne 2 ]; then
                ErrorFound="The elements in the range have to be different"
            else
                Range=($(seq ${Range[0]} ${Range[1]}))
            fi
        fi
    else
        if [ -n "$1" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
            Range+=($1)
        else
            ErrorFound="Only numbers in range"
        fi
    fi
    Result=$(IFS=, ; echo "${Range[*]}")
    echo "$Result"
}

function CheckImageFile
{
    if [ ! -f "$1" ]; then
        ErrorFound="Image file \"$1\" does not exist"
    fi    
}

function CheckRegionName
{
    for r in $(echo "$RegionNames" | tr "," "\n"); do
        if [[ "$1" == "$r" ]]; then
            return
        fi
    done
    ErrorFound="Region name \"$1\" is not valid"
}

function ReserveEphemerals
{
    new_reserve=""
    if [ "$1" == "Undefined" ]; then
        new_reserve="44301-44399"
    else
        new_reserve=$1
    fi

    new_reserve="${new_reserve},8001-8099"
    new_reserve="${new_reserve},1201-1299"

    old_reserve=`cat /proc/sys/net/ipv4/ip_local_reserved_ports`
    if [ "$new_reserve" != "$old_reserve" ]; then
        echo "Reserving ephemeral ports:";         
        echo "- old value: `cat /proc/sys/net/ipv4/ip_local_reserved_ports`"
        echo $new_reserve > /proc/sys/net/ipv4/ip_local_reserved_ports
        echo "- new value: `cat /proc/sys/net/ipv4/ip_local_reserved_ports`"
    fi
}

function CheckForDuplicatedCommand
{
    if [ "$1" != "Undefined" ]; then
        echo "The commands paramaters are mutually exclusive."
        echo "Please use -h or --help argument for help."
        exit 1
    fi
}

function CheckParameters
{
    Positional=()

    Command="$1"
    case $Command in

            -C|--create)
                Command="Create"
            ;;

            -X|--execute)
                Command="Execute"
            ;;

            -U|--update)
                Command="Update"
            ;;

            -D|--delete)
                Command="Delete"
            ;;
    
            -L|--get_logs)
                Command="Logs"
            ;;
      
            -S|--get_stats)
                Command="Stats"
            ;;

            -H|-h|--help)
                Command="Help"
            ;;

            *)    # unknown command
                echo "Unrecognized command \"$Command\". Use -h or --help argument for help."
                exit 1
            ;;
    esac

    shift # past argument

    CRS_eph_ports_reserv="Undefined"
       
    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in

            -j|--jobs)
                if [[ $HasParamJ = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamJ=true
                JobsLevel=${2}
                shift # past argument
                shift # past value
            ;;

            -r|--range)
                if [[ $HasParamR = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamR=true
                CheckRangeResult=$(CheckRangeValue $2)
                if [ ! -z "$ErrorFound" ]; then
                    echo "$ErrorFound"
                    echo "Use -h or --help argument for help."
                    exit 1
                fi
                RangeResult=(`echo $CheckRangeResult | sed 's/,/\n/g'`)
                shift # past argument
                shift # past value
            ;;

            -t|--timezone)
                if [[ $HasParamT = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamT=true
                Container_Timezone=${2}
                shift # past argument
                shift # past value
            ;;

            -f|--crs_folder)
                if [[ $HasParamF = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamF=true
                PersistencyDir=`readlink -f ${2}`
                shift # past argument
                shift # past value
            ;;

            -s|--storage_folder)
                HasParamS=true
                StorageFolders+=(`readlink -f ${2}`)
                shift # past argument
                shift # past value
            ;;

            -i|--image)
                if [[ $HasParamI = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamI=true
                CheckImageFile $2
                if [ ! -z "$ErrorFound" ]; then
                    echo "$ErrorFound"
                    echo "Use -h or --help argument for help."
                    exit 1
                fi
                CRS_docker_image_file=`readlink -f ${2}`
                shift # past argument
                shift # past value
            ;;

            -p|--ports)
                if [[ $HasParamP = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamP=true
                CRS_eph_ports_reserv=${2}
                shift # past argument
                shift # past value
            ;;

            --usermode)
                RunAsRoot=false
                shift # past argument
            ;;

            -y|--yes)
                YesToAllQuestions=true
                shift # past argument
            ;;

            --enable-core-dump)
                EnableCoreDump=true
                shift # past argument
            ;;

            --debug)
                EnableDebug=true
                shift # past argument
            ;;
            
            --provisioning_region)
                if [[ $HasParamProvisioningRegion = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamProvisioningRegion=true
                CheckRegionName $2
                if [ ! -z "$ErrorFound" ]; then
                    echo "$ErrorFound"
                    echo "Use -h or --help argument for help."
                    exit 1
                fi
                CRS_provisioning_region=${2}
                shift # past argument
                shift # past value
            ;;

            --provisioning_password)
                if [[ $HasParamProvisioningPassword = true ]]; then
                    echo "Error: duplicated parameter $key"
                    exit 1
                fi
                HasParamProvisioningPassword=true
                CRS_provisioning_password=${2}
                shift # past argument
                shift # past value
            ;;

            *)    # unknown option
                echo "Unrecognized option \"$key\". Use -h or --help argument for help."
                exit 1
            ;;
        esac
    done
    set -- "${Positional[@]}" # restore positional parameters
}

function CreateCRSFolders
{
    if [ ! -d "${PersistencyDir}" ]; then
        mkdir -p "${PersistencyDir}"
    fi
}

function LoadImage
{
    CRS_docker_loaded_image_tag=`docker load < $1`
    
    if [ -z "$CRS_docker_loaded_image_tag" ]; then
        ErrorFound="Error loading image file \"$1\""
        return
    fi

    echo $CRS_docker_loaded_image_tag

    CRS_docker_loaded_image_tag=`grep "^Loaded image: " <<< "$CRS_docker_loaded_image_tag"`
    CRS_docker_loaded_image_tag=${CRS_docker_loaded_image_tag#"Loaded image: "}
    # echo ${_GREEN_}CRS_docker_loaded_image_tag value is \"$CRS_docker_loaded_image_tag\"${_RESETCOLOR_}
    
    docker tag $CRS_docker_loaded_image_tag $CRS_docker_image_tag
}

function GetLogs
{
    rm -rf __TempToPrepareLogs__
    mkdir __TempToPrepareLogs__
    for i in "${RangeResult[@]}"; do
        CRSName="crs${i}"
        mkdir "__TempToPrepareLogs__/${CRSName}"
        CheckIfCRSRunning=$(docker ps | grep -w ${CRSName})
        if [ -z "${CheckIfCRSRunning}" ]; then
            # CRS not running or not existing
            ConfigDirName="${PersistencyDir}/crs${i}"
            cp -a "${ConfigDirName}/_server_data/LOGS" "__TempToPrepareLogs__/${CRSName}"
        else
            docker cp -a "${CRSName}:/CRS/_server_data/LOGS" "__TempToPrepareLogs__/${CRSName}"
        fi
        cd __TempToPrepareLogs__
        tar cvfz "../${CRSName}_Logs.tar.gz" "${CRSName}/" >/dev/null
        cd ..
        rm -rf "__TempToPrepareLogs__/${CRSName}"
    done
    rm -rf __TempToPrepareLogs__
}

function GetStats
{
    ValidContainers=$(docker container ls)
    CRSNameList=""
    # Order correctly the list of containers to analyze
    RangeResultSorted=(`echo ${RangeResult[@]} | tr " " "\n" | sort -V`)
    if [ "$RangeResultSorted" != "" ]; then
        echo
        echo "${_GREEN_}Containers Ports${_RESETCOLOR_}" 
    fi
    for i in "${RangeResultSorted[@]}"; do
        toSearch="crs${i}"
        if echo "$ValidContainers" | grep -w -q "$toSearch"; then
            suffixPort="0${i}"
            if [ ${i} -gt 9 ]; then
                suffixPort="${i}"
            fi
            CRSNameList+="crs${i} "
            echo "crs${i} container ports: ${_YELLOW_}443${suffixPort}${_RESETCOLOR_} (https), ${_YELLOW_}80${suffixPort}${_RESETCOLOR_} (http) and ${_YELLOW_}12${suffixPort}${_RESETCOLOR_} (redundancy) " 
        else
            echo "${_RED_}No running container crs${i}${_RESETCOLOR_}"
        fi
    done
    echo
    echo "${_GREEN_}Containers Statistics${_RESETCOLOR_}"
    docker stats $CRSNameList --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.NetIO}}\t{{.MemPerc}}\t{{.MemUsage}}'
    echo
    echo "${_GREEN_}Host Information${_RESETCOLOR_}"
    stats=$(docker info --format 'Kernel Version:{{.KernelVersion}},Operating System: {{.OperatingSystem}},Architecture: {{.Architecture}},Number of CPUs: {{.NCPU}},Total Memory: {{.MemTotal}}')
    HostStatistics=${stats//,/'\n'}
    echo -e $HostStatistics
    echo
}

# # Size check temporary removed
# Get information about the disk
# AvailableSpaceInBytes=`df ${PersistencyDir} -B1 --output=avail | sed '1d'`
# AvailSpaceInBytesForEachCRS=$((AvailableSpaceInBytes / NumContainers))

# # If there is not enough space to allocate for the storeage for all required containers, the script will exit

# if [ ${AvailSpaceInBytesForEachCRS} -le 10737418240 ]; then
#     AvailableSpace=df ${PersistencyDir} -h --output=avail | sed '1d'
#     echo ""
#     echo "${_RED_}Not enough disk space for storage for all the required containers"
#     echo ""
#     echo "${_YELLOW_}Total available space for all containers: ${AvailableSpace}"
#     echo "Number of container requested: ${NumContainers}"
#     echo "Minimum disk space necessary for each container 10G${_RESETCOLOR_}"
#     echo ""
#     exit 1
# fi

function GetMountPath
{
    currpath=$1
    currpath=$(readlink -f "$currpath")
    if [[ -z $currpath ]]; then
        mountpoint=""
    else
        mountpoint=$(df -P "$currpath" | tail -n +2 | awk '{if(NF>=6){print $6}}')
    fi
    echo $mountpoint
}

function CreateContainers
{
    for i in "${RangeResult[@]}"; do
        # create container if missing 
        ConfigDirName="${PersistencyDir}/crs${i}"
        CRSName="crs${i}"

        if [ ! -d ${ConfigDirName} ]; then
            # config folder not existing
            echo "${_YELLOW_}Creating ${CRSName} config folders${_RESETCOLOR_}"
            mkdir -p ${ConfigDirName}/_reg_data
            mkdir -p ${ConfigDirName}/_server_data
        fi
        
        isCRSRunning=$(docker ps | grep -w ${CRSName})
        if [ -z "${isCRSRunning}" ]; then
            # not running
            echo "${_YELLOW_}Starting Docker Image ${CRSName}${_RESETCOLOR_}"
            containerHostName=$(cat /etc/hostname)"_${CRSName}"
            StorageVolumes=""
            counter=0
            for s in "${StorageFolders[@]}"; do
                ((++counter))
                mountpath=$(GetMountPath $s)
                if [[ ! -z $mountpath ]]; then
                    mkdir -p "${mountpath}/INF"
                    StorageVolumes="${StorageVolumes} -v ${s}:/mnt/storagecrs${counter} -v ${mountpath}/INF:/mnt/storagecrs${counter}/STORAGE/INF"
                else
                    echo "${_RED_}WARN: cannot determine mount point for ${s}, the path won\'t be bound to the container.${_RESETCOLOR_}"
                fi
            done
            spectivaVideoPort=$(( 1200 + ${i} ))

            DebugParams=""
            if [[ $EnableDebug = true ]]; then
                DebugParams="--cap-add SYS_PTRACE"
            fi
            
            ProvisioningRegionParam=""
            if [ ! -z "${CRS_provisioning_region}" ]; then
                ProvisioningRegionParam="--env crs_provisioning_region=${CRS_provisioning_region}"
            fi

            if [ ! -z "${CRS_provisioning_password}" ]; then
                echo "${CRS_provisioning_password}" > "${ConfigDirName}/_reg_data/crs_provisioning_admin_pwd"
            fi
            
            docker run -d \
            --log-driver json-file \
                --log-opt max-size=50m \
                --log-opt max-file=5 \
                --log-opt compress=true \
            --ulimit core=5000000:5000000 \
            --network host -h ${containerHostName} \
            --restart unless-stopped \
            --name ${CRSName} \
                ${StorageVolumes} \
                -v /dev:/dev_external:ro \
                -v /sys:/sys_external:ro \
                -v /etc:/etc_external:ro \
                -v ${ConfigDirName}/_server_data:/CRS/_server_data_docker \
                -v ${ConfigDirName}/_reg_data:/CRS/_reg_data_docker \
            --env spectiva_video_port=${spectivaVideoPort} \
            --env CRSDockerContainerName=${CRSName} \
            --env crs_jobs_level=${JobsLevel} \
            --env docker_mode_enabled=true \
            --env ContainerTimeZone=${Container_Timezone} \
            ${ProvisioningRegionParam} \
            --cap-add SYS_ADMIN --cap-add DAC_READ_SEARCH \
            ${DebugParams} \
            ${CRS_docker_image_tag}
        else
            echo "${_GREEN_}Docker Image ${CRSName} already running${_RESETCOLOR_}"
        fi
    done
}

function RemoveContainers
{
    for i in "${RangeResult[@]}"; do
        echo ""
        CRSName="crs${i}"
        docker rm -f ${CRSName}
        echo "${_GREEN_}Docker ${CRSName} removed${_RESETCOLOR_}"
        echo ""
    done
}

function CheckRootPrivileges
{
    if [[ $RunAsRoot = true && $(/usr/bin/id -u) -ne 0 ]]; then
        echo "Run the script with root privileges."
        exit 1
    fi
}

function EnableCoreDumpIfRequested
{
    if [[ $EnableCoreDump = true ]]; then
        if [[ $RunAsRoot = false ]]; then
            echo "--enable-core-dump option requires root privileges."
            exit 1
        fi
        echo "Changing OS settings to make CRS core dumps available. On Ubuntu Apport will stop to collect sytem crashes."
        ulimit -c unlimited
        sysctl -w kernel.core_pattern=/var/crash/core-%e.%p.%h.%t
    fi
}

function main
{
    CheckParameters $@

    if [ "$Command" == "Create" ]; then
        if [[ $HasParamR = false || $HasParamI = false || $HasParamF = false || ($HasParamProvisioningRegion = false && $HasParamProvisioningPassword = true) ]]; then
            echo "Error: missing parameters. Use -h for help."
            exit 1
        fi
        CheckRootPrivileges
        EnableCoreDumpIfRequested
        CreateCRSFolders
        LoadImage $CRS_docker_image_file
        if [ ! -z "$ErrorFound" ]; then
            echo "$ErrorFound"
            echo "Use -h or --help argument for help."
            exit 1
        fi
        ReserveEphemerals $CRS_eph_ports_reserv
        CreateContainers
    elif [ "$Command" == "Update" ]; then
        if [[ $HasParamR = false || $HasParamI = false || $HasParamF = false || ($HasParamProvisioningRegion = false && $HasParamProvisioningPassword = true) ]]; then
            echo "Error: missing parameters. Use -h for help."
            exit 1
        fi
        CheckRootPrivileges
        EnableCoreDumpIfRequested
        RemoveContainers
        CreateCRSFolders
        LoadImage $CRS_docker_image_file
        if [ ! -z "$ErrorFound" ]; then
            echo "$ErrorFound"
            echo "Use -h or --help argument for help."
            exit 1
        fi
        ReserveEphemerals $CRS_eph_ports_reserv
        CreateContainers
    elif [ "$Command" == "Execute" ]; then
        if [[ $HasParamR = false || $HasParamF = false || ($HasParamProvisioningRegion = false && $HasParamProvisioningPassword = true) ]]; then
            echo "Error: missing parameters. Use -h for help."
            exit 1
        fi
        if [[ $HasParamI = true ]]; then
            echo "Error: unexpected parameter -i. Use -h for help."
            exit 1
        fi
        CheckRootPrivileges
        EnableCoreDumpIfRequested
        CreateCRSFolders
        ReserveEphemerals $CRS_eph_ports_reserv
        CreateContainers
    elif [ "$Command" == "Delete" ]; then
        if [[ $HasParamR = false ]]; then
            echo "Error: missing parameters. Use -h for help."
            exit 1
        fi
        if [[ $HasParamI = true || $HasParamF = true || $HasParamS = true || $HasParamJ = true || $HasParamT = true || $HasParamP = true || $HasParamProvisioningRegion = true || $HasParamProvisioningPassword = true ]]; then
            echo "Error: unexpected parameter. Use -h for help."
            exit 1
        fi
        Proceed=false
        if [[ $YesToAllQuestions = true ]]; then
            Proceed=true
        else
            read -p "This will delete the containers in the specified range, are you sure? [y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                Proceed=true
            fi
        fi
        if [[ $Proceed = true ]]; then
            CheckRootPrivileges
            EnableCoreDumpIfRequested
            RemoveContainers
        else
            echo "No containers were deleted."
        fi
    elif [ "$Command" == "Stats" ]; then
        if [[ $HasParamI = true || $HasParamF = true || $HasParamS = true || $HasParamJ = true || $HasParamT = true || $HasParamP = true || $HasParamProvisioningRegion = true || $HasParamProvisioningPassword = true ]]; then
            echo "Error: unexpected parameter. Use -h for help."
            exit 1
        fi
        CheckRootPrivileges
        EnableCoreDumpIfRequested
        GetStats
    elif [ "$Command" == "Logs" ]; then
        if [[ $HasParamR = false ]]; then
            echo "Error: missing parameters. Use -h for help."
            exit 1
        fi
        if [[ $HasParamI = true || $HasParamS = true || $HasParamJ = true || $HasParamT = true || $HasParamP = true || $HasParamProvisioningRegion = true || $HasParamProvisioningPassword = true ]]; then
            echo "Error: unexpected parameter. Use -h for help."
            exit 1
        fi
        CheckRootPrivileges
        EnableCoreDumpIfRequested
        GetLogs
    elif [ "$Command" == "Help" ]; then
        PrintHelp
    else
        echo "Unrecognized command. Use -h or --help argument for help."
        exit 1
    fi
}

main $@
