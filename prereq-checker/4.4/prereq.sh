#!/bin/bash
# © Copyright IBM Corp. 2020, 2024

set -eo pipefail

## Resource size for 4.4
# These defaults are given in section 'IBM Cloud Pak for AIOps only Hardware requirement totals' under
# 'Hardware requirements - IBM Cloud Pak for AIOps only' https://ibm.biz/aiops_hardware_440
# Minimum resource values for small profile 4.4.x
NODE_COUNT_SMALL_4_4=3
VCPU_SMALL_4_4=62
MEMORY_SMALL_4_4=140
# Minimum resource values for large profile 4.4.x
NODE_COUNT_LARGE_4_4=10
VCPU_LARGE_4_4=162
MEMORY_LARGE_4_4=372


log () {
    local log_tracing_prefix=$1
    local log_message=$2
    local log_options=$3

    if [[ ! -z $log_options ]]; then
        echo $log_options "$log_tracing_prefix $log_message"
    else
        echo "$log_tracing_prefix $log_message"
    fi
}

initialize() {

    command="oc"
    notop=""
    adm="adm"
    unitNotSupported="false"

    # Tracing prefixes
    INFO="[INFO]"
    WARNING="[WARNING]"
    ERROR="[ERROR]"

    # For Summary method
    OCP_VER_RES=""
    STORAGE_PROVIDER_RES=""
    PROFILE_RES=""
    PS_RES=""
    CERTMANAGER_PRESENT=""
    LICENSING_PRESENT=""

    warn_color="\x1b[33m"
    fail_color="\x1b[31m"
    pass_color="\e[32m"
    color_end="\x1b[0m"

    fail_msg=`printf "$fail_color FAIL $color_end"`
    pass_msg=`printf "$pass_color PASS $color_end\n"`
    warning_msg=`printf "$warn_color WARNING $color_end"`
    skip_msg=`printf "$warn_color SKIP $color_end"`

    # array to hold all storage check results
    storageCheckRes=()
}

display_help() {
    echo "**************************************** Usage ********************************************"
    echo
    echo " This script ensures that you have met the technical prerequisites for IBM Cloud Pak for AIOps version 4.4."
    echo
    echo " Before you run this script, you will need: "
    echo " 1. OpenShift (oc) command line interface (CLI)"
    echo " 2. Must be logged in to your cluster with oc login"
    echo " 3. Must be in the project (namespace) you have installed or will install the product in"
    echo
    echo " Usage:"
    echo " ./prereq.sh -h"
    echo "  -h Prints out the help message"
    echo " ./prereq.sh -o"
    echo "  -o Skips storageclass checks when using alternate storage providers"
    echo "*******************************************************************************************"
}

# Add options as needed
while getopts 'hsuo' opt; do
    case "$opt" in
        h)
            display_help
            exit 0
            ;;
        o)
            SKIP_STORAGE_CHECK="true"
            ;;
    esac
done
shift "$(($OPTIND -1))"

# Verify oc is installed & we are logged into the cluster
if ! [ -x "$(command -v oc)" ]; then
    log $ERROR "oc CLI is not installed.  Please install the oc CLI and try running the script again."
    exit 1
fi

oc project
if [ $? -gt 0 ]; then
    log $ERROR "oc login required.  Please login to the cluster and try running the script again."
    exit 1
fi

echo
log $INFO "Starting IBM Cloud Pak for AIOps prerequisite checker v4.4..."
echo

# This function checks to see if user's OCP version meets our requirements by checking if 
# substring "4.11", "4.12", "4.13", or "4.14" is in variable OCP_VER.
function checkOCPVersion {
    
    OCP_VER=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')

    ODF_STORAGE=$(oc get storageclass ocs-storagecluster-cephfs --ignore-not-found=true)

    OCP_MINOR_VER=`echo $OCP_VER | awk '{split($0,a,"."); print a[3]}'`
    
    echo
    startEndSection "Openshift Container Platform Version Check"
    log $INFO "Checking OCP Version. Compatible Versions of OCP is v4.11 (non-FIPS enabled cluster), v4.12, v4.13, and v4.14 (homogenous clusters only)."
    
    if [[ $OCP_VER == *"4.12"* ||  $OCP_VER == *"4.13"* ]]; then
        printf "$pass_color$INFO OCP version $OCP_VER is compatible.$color_end\n"

        OCP_VER_RES=$pass_msg
        startEndSection "Openshift Container Platform Version Check"
        return 0
    elif [[ $OCP_VER == *"4.11"* &&  ! -z "$(oc get mc -o jsonpath='{.items[?(.spec.fips==true)].metadata.name}')" ]]; then
        printf "$fail_color$ERROR OCP version $OCP_VER is compatible for only non-FIPS enabled clusters.$color_end\n"
        OCP_VER_RES=$fail_msg
        startEndSection "Openshift Container Platform Version Check"
        return 1
    elif [[ $OCP_VER == *"4.11"* &&  -z "$(oc get mc -o jsonpath='{.items[?(.spec.fips==true)].metadata.name}')" ]]; then
        printf "$fail_color$ERROR OCP version $OCP_VER is compatible for only non-FIPS enabled clusters.$color_end\n"
        OCP_VER_RES=$pass_msg
        startEndSection "Openshift Container Platform Version Check"
        return 0
    elif [[ $OCP_VER == *"4.14"* ]]; then
        printf "$pass_color$INFO OCP version $OCP_VER is compatible but only nodes with AMD64 architectures are supported at this time. $color_end\n"
        OCP_VER_RES=$pass_msg
        startEndSection "Openshift Container Platform Version Check"
        return 0
    else
        printf "$fail_color$ERROR OCP Version is incompatible. Required Versions: v4.11 (non-FIPS enabled cluster), v4.12, v4.13, and v4.14 (homogenous clusters only). $color_end\n"
        log $ERROR "Your Version: v$OCP_VER"
        echo
        OCP_VER_RES=$fail_msg
        startEndSection "Openshift Container Platform Version Check"
        return 1
    fi
}

# Check for entitlement or global pull secret
checkEntitlementSecret () {
    
    SECRET_NAME="ibm-entitlement-key"
    ENTITLEMENT_SECRET=$(oc get secret | grep $SECRET_NAME)
    GLOBAL_PULL_SECRET=$(oc get secret pull-secret -n openshift-config)

    echo
    startEndSection "Entitlement Pull Secret"
    log $INFO "Checking whether the Entitlement secret or Global pull secret is configured correctly."
    

    if [[ -z $ENTITLEMENT_SECRET && -z $GLOBAL_PULL_SECRET ]] ; then
        printf " $fail_color $ERROR Ensure that you have either a '$SECRET_NAME' secret or a global pull secret 'pull-secret' configured in the namespace 'openshift-config'. $color_end\n"
        PS_RES=$fail_msg
        startEndSection "Entitlement Pull Secret"
        return 1
    else
        createTestJob
    fi
}

createTestJob () {
    JOB_NAME="cp4aiops-entitlement-key-test-job"

    # Use return the word count of "oc get jobs $JOB_NAME"
    wc=`oc get job $JOB_NAME --no-headers=true --ignore-not-found=true | wc -l`

    log $INFO "Checking if the job '$JOB_NAME' already exists."
    if [ "${wc}" -gt 0  ]; then
        oc delete job $JOB_NAME
        sleep 10
    else
        log $INFO "The job with name '$JOB_NAME' was not found, so moving ahead and creating it."
    fi

    if [[ $ENTITLEMENT_SECRET ]] ; then
        log $INFO "Creating the job '$JOB_NAME' "
        exec 3>&2
        exec 2> /dev/null
        cat <<EOF | oc apply -f -
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: cp4aiops-entitlement-key-test-job
    spec:
      parallelism: 1
      completions: 1
      template:
        metadata:
          name: pi
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                    - key: kubernetes.io/arch
                      operator: In
                      values:
                        - amd64
          imagePullSecrets:
          - name: ibm-entitlement-key
          containers:
          - name: testimage
            image: cp.icr.io/cp/cp4waiops/ai-platform-api-server@sha256:de3d762cb51ca3c2e2395c08b3dc9726316dc42a1f28de65019960abb527d100
            imagePullPolicy: Always
            command: [ "echo", "SUCCESS" ]
          restartPolicy: OnFailure
EOF
        exec 2>&3
    else
        log $INFO "Creating the job '$JOB_NAME' "
        exec 3>&2
        exec 2> /dev/null
        cat <<EOF | oc apply -f -
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: cp4aiops-entitlement-key-test-job
    spec:
      parallelism: 1
      completions: 1
      template:
        metadata:
          name: pi
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                    - key: kubernetes.io/arch
                      operator: In
                      values:
                        - amd64
          containers:
          - name: testimage
            image: cp.icr.io/cp/cp4waiops/ai-platform-api-server@sha256:de3d762cb51ca3c2e2395c08b3dc9726316dc42a1f28de65019960abb527d100
            imagePullPolicy: Always
            command: [ "echo", "SUCCESS" ]
          restartPolicy: OnFailure
EOF
        exec 2>&3
    fi
    sleep 3
    checkEntitlementCred
}

checkEntitlementCred () {
    
    SLEEP_LOOP=5
    IMAGE_PULL_STATUS_FLAG="false"
    log $INFO "Verifying if the job '$JOB_NAME' completed successfully.."
    POD_NAME=$(oc get pod -o name | grep $JOB_NAME)

    if [[ ! -z $POD_NAME ]];then
        LOOP_COUNT=0
        while [ $LOOP_COUNT -lt 25 ]
        do
            phase_status=$(oc get $POD_NAME -o jsonpath='{.status.phase}')
            if [[ $phase_status == "Succeeded" ]];then
                container_status=$(oc get $POD_NAME -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}')
                if [[ "$container_status" != "ErrImagePull" && "$container_status" != "ImagePullBackOff" ]]; then
                    if [[ "$container_status" == "Completed" ]]; then
                        image_pull_status_flag="true"
                        break
                    fi
                fi
            elif [[ $phase_status == "Pending" ]];then
                container_status=$(oc get $POD_NAME -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')
                if [[ "$container_status" == "ErrImagePull" || "$container_status" == "ImagePullBackOff" ]]; then
                    image_pull_status_flag="false" 
                fi
            fi
            sleep $SLEEP_LOOP
            LOOP_COUNT=`expr $LOOP_COUNT + 1`
        done
    else
        printf " $fail_color $ERROR Some error occured while '$JOB_NAME' job creation for testing entitlement secret configuration. $color_end\n"
        startEndSection "Entitlement Pull Secret"
        return 1
    fi
    
    #Checking the job pod logs, where we chose to just print 'SUCCESS' message.
    if [[ "$image_pull_status_flag" == "true" ]]; then
        logs_status=$(oc logs $POD_NAME)
        if [[ $logs_status == "SUCCESS"  ]];then
            log $INFO "SUCCESS! Entitlement secret is configured correctly."
            PS_RES=$pass_msg
        else
            printf "$fail_color $ERROR Some error occured in validating job '$JOB_NAME' logs, error validating the entitlement secret $color_end\n"
            PS_RES=$fail_msg
        fi
    else
        PS_RES=$fail_msg
        printf "$fail_color $ERROR The pod '$POD_NAME' failed with container_status='$container_status' $color_end\n"
        printf "$fail_color $ERROR Entitlement secret is not configured correctly. $color_end\n"
    fi
    
    #cleaning the job in case if script reaches here.
    oc delete job $JOB_NAME
    startEndSection "Entitlement Pull Secret"
}

function checkAllowVolumeExpansion() {
    storageclass=$1
    
    volumeExpansionEnabled=$(oc get storageclass $storageclass -o=jsonpath='{.allowVolumeExpansion}')
    if [[ "${volumeExpansionEnabled}" != "true" ]]; then
        return 1
    fi

    return 0
}

function checkIBMSpectrum {
    MEETS_OCP_VERSION="false"

    printf "\nChecking if IBM Storage Fusion is configured properly...\n"

    # Check OCP version is 4.12
    OCP_VER=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')
    if [[ "$OCP_VER" == *"4.12"* ]]; then
        # If it meets the ocp version requirement... check if ibm-spectrum-scale-sc storageclass has volume expansion enabled
        IBM_SPEC_VE=$(checkAllowVolumeExpansion ibm-spectrum-scale-sc)
        if [[ "$?" == "1" ]]; then
            printf "${fail_color}${ERROR} StorageClass ibm-spectrum-scale-sc does not have allowedVolumeExpansion enabled. This is required for all large profile installs and strongly recommended for small profile installs. See \"Storage Class Requirements\" section in https://ibm.biz/storage_consideration_440 for details.$color_end\n"
            storageCheckRes+=("fail")
            return 1
        fi
        
        storageCheckRes+=("pass")
        printf "IBM Storage Fusion looks fine."
        return 0
    else
        # OCP 4.12 was not found... fail this check
        printf "${fail_color}${ERROR}If you intend to use Storage Fusion with AIOPS 4.4, you must have 4.12 $color_end\n"
        log $INFO "See Readme for more info about this."
        storageCheckRes+=("fail")
        return 1
    fi
}

function checkODF {
    ODF_PODS=$1
    printf "\nChecking Openshift Data Foundation Configuration...\n"
    printf "Verifying if Red Hat Openshift Data Foundation pods are in \"Running\" or \"Completed\" status\n"

    for p in "${ODF_PODS[@]}"; do
        podStatus=$(oc get pod $p -n openshift-storage -o jsonpath='{.status.phase}')
        if [[ "$podStatus" == "Running" || "$podStatus" == "Succeeded" ]]; then
            continue
        else
            printf "$fail_color $ERROR Pod in openshift-storage project namespace found not \"Running\" or \"Completed\": $p $color_end\n"
            storageCheckRes+=("fail")
            return 1
        fi
    done

    log $INFO "Pods in openshift-storage project are \"Running\" or \"Completed\""

    ODF_STORAGECLASSES=("ocs-storagecluster-ceph-rbd" "ocs-storagecluster-cephfs")
    for s in "${ODF_STORAGECLASSES[@]}"; do
        oc get storageclass $s > /dev/null 2>&1
        if [[ "$?" == "0" ]]; then
            log $INFO "$s exists."
        else
            printf "$warn_color$WARNING $s does not exist. $color_end\n"
            storageCheckRes+=("warn")
            return 1
        fi
    done

    # Check if each ODF StorageClass has allowVolumeExpansion enabled. If not set the ODF_VE_FLAG to true
    ODF_VE_FLAG="false"
    for s in "${ODF_STORAGECLASSES[@]}"; do
        VE_CHECK=$(checkAllowVolumeExpansion $s)
        if [[ "$?" == "1" ]]; then
            printf " $fail_color $ERROR StorageClass $s does not have allowedVolumeExpansion enabled. This is required for all large profile installs and strongly recommended for small profile installs. See \"Storage Class Requirements\" section in https://ibm.biz/storage_consideration_440 for details.$color_end\n"
            ODF_VE_FLAG="true"
        fi
    done

    # If the ODF_VE_FLAG is true, then that means a sc has been found that has allowvolumeexpansion disabled or missing. In that case, we'll go ahead and
    # output a failure for this check
    if [[ "$ODF_VE_FLAG" == "true" ]]; then
        storageCheckRes+=("fail")
        return 1
    fi

    storageCheckRes+=("pass")
    return 0
}


function checkPortworx {
    PORTWORX_WARNING="false"
    printf "\nChecking Portworx Configuration...\n"

    printf "Checking for storageclass \"portworx-fs\"...\n"
    oc get storageclass portworx-fs > /dev/null 2>&1
    if [[ "$?" == "0" ]]; then
        log $INFO "StorageClass \"portworx-fs\" exists."
    else
        PORTWORX_WARNING="true"
        echo
        log $WARNING "StorageClass \"portworx-fs\" does not exist. See \"Portworx Storage\" section in https://ibm.biz/storage_consideration_440 for details."
    fi

    printf "Checking for storageclass \"portworx-aiops\"...\n"
    oc get storageclass portworx-aiops > /dev/null 2>&1
    if [[ "$?" == "0" ]]; then
        log $INFO "StorageClass \"portworx-aiops\" exists."
    else
        PORTWORX_WARNING="true"
        echo
        log $WARNING "StorageClass \"portworx-aiops\" does not exist. See \"Portworx Storage\" section in https://ibm.biz/storage_consideration_440 for details."
    fi
    
    portworx_fs=$(checkAllowVolumeExpansion portworx-aiops)
    if [[ "$?" == "1" ]]; then
        echo
        printf " $fail_color $ERROR StorageClass portworx-aiops does not have allowedVolumeExpansion enabled. This is required for all large profile installs and strongly recommended for small profile installs. See \"Storage Class Requirements\" section in https://ibm.biz/storage_consideration_440 for details.$color_end\n"
        storageCheckRes+=("fail")
        return 1
    fi

    portworx_block=$(checkAllowVolumeExpansion portworx-fs)
    if [[ "$?" == "1" ]]; then
        echo
        printf " $fail_color $ERROR StorageClass portworx-fs does not have allowedVolumeExpansion enabled. This is required for all large profile installs and strongly recommended for small profile installs. See \"Storage Class Requirements\" section in https://ibm.biz/storage_consideration_440 for details.$color_end\n"
        storageCheckRes+=("fail")
        return 1
    fi
    
    if [[ "$PORTWORX_WARNING" == "false" ]]; then
        storageCheckRes+=("pass")
    else
        storageCheckRes+=("warn")
    fi
    
    return 0
}

function checkIBMCFileGoldGidStorage {
    printf "Checking if IBM Cloud Storage is configured properly...\n"

    file=$(oc get storageclass ibmc-file-gold-gid --ignore-not-found=true)
    block=$(oc get storageclass ibmc-block-gold --ignore-not-found=true)

    if [[ "$file" == "" || "$block" == "" ]]; then
        printf "$fail_color $ERROR Both ibmc-block-gold and ibmc-file-gold-gid need to exist to use IBM Cloud Storage. See \"Storage\" section in https://ibm.biz/storage_consideration_440 for details. $color_end\n"
        storageCheckRes+=("fail")
        return 1 
    fi

    VE_BLOCK=$(checkAllowVolumeExpansion ibmc-block-gold)
    if [[ "$?" == "1" ]]; then
        printf " $fail_color $ERROR StorageClass ibmc-block-gold does not have allowedVolumeExpansion enabled. This is required for all large profile installs and strongly recommended for small profile installs. See \"Storage Class Requirements\" section in https://ibm.biz/storage_consideration_440 for details.$color_end\n"
        storageCheckRes+=("fail")
        return 1
    fi

    VE_FILE=$(checkAllowVolumeExpansion ibmc-file-gold-gid)
    if [[ "$?" == "1" ]]; then
        printf " $fail_color $ERROR StorageClass ibmc-file-gold-gid does not have allowedVolumeExpansion enabled. This is required for all large profile installs and strongly recommended for small profile installs. See \"Storage Class Requirements\" section in https://ibm.biz/storage_consideration_440 for details.$color_end\n"
        storageCheckRes+=("fail")
        return 1
    fi

    storageCheckRes+=("pass")
}

function checkStorage {
    # Initialize an empty array. If storage provider is found, append the name as an element...
    storageFound=()

    if [[ $SKIP_STORAGE_CHECK == "true" ]]; then
        echo
        startEndSection "Storage Provider"
        log $INFO "Skipping storage provider check"
        startEndSection "Storage Provider"
        STORAGE_PROVIDER_RES=$skip_msg
        return 0
    fi

    echo
    startEndSection "Storage Provider"
    log $INFO "Checking storage providers"

    # Check for Storage Fusion
    IBM_SPEC_FUSION=$(oc get storageclass ibm-spectrum-scale-sc --ignore-not-found=true)
    if [[ "$IBM_SPEC_FUSION" != "" ]]; then
        echo
        log $INFO "A storage class related to Storage Fusion was found."
        storageFound+=("ibm-spec")
    else
        log $INFO "No IBM Storage Fusion Found... Skipping configuration check."
    fi

    # Check for any hints portworx is deployed. In this scenario, we look for any storage clusters that are deployed in all namespaces. Then
    # we check if the keyword "Running"
    STORAGE_CLUSTER=$(oc get storagecluster.core.libopenstorage.org -A --ignore-not-found=true --no-headers=true 2>>/dev/null)
    if [[ "$STORAGE_CLUSTER" == *"Running"* || "$STORAGE_CLUSTER" == *"Online"* ]]; then
        log $INFO "Portworx Found. StorageCluster instance in \"Running\" or \"Online\" status found."
        storageFound+=("portworx")
    else
        echo
        log $INFO "No Portworx StorageClusters found with \"Running\" or \"Online\" status. Skipping configuration check for Portworx."
    fi

    # Check for ODF...
    ODF_PODS=($(oc get pods -n openshift-storage --no-headers=true | awk '{print $1}'))
    if [[ "$ODF_PODS" == "" ]]; then
        echo
        log $INFO "Openshift Data Foundation not running. Skipping configuration check for ODF."
    else
        log $INFO "Openshift Data Foundation found."
        storageFound+=("odf")
    fi

    # Check for IBM Cloud Storage...
    IBMC_FILE_GOLD_GID=$(oc get storageclass ibmc-file-gold-gid --ignore-not-found=true)
    IBMC_BLOCK_GOLD_GID=$(oc get storageclass ibmc-block-gold --ignore-not-found=true)
    if [[ "$IBMC_FILE_GOLD_GID" != "" || "$IBMC_BLOCK_GOLD_GID" != ""  ]]; then
        echo
        log $INFO "IBM Cloud Storage found."
        storageFound+=("ibmc")
    else
        log $INFO "No IBM Cloud Storage found... Skipping configuration check for IBM Cloud Storage Check."
    fi

    # If no storageProviders were found, print an error...
    if [ ${#storageFound[@]} -eq 0 ]; then
        STORAGE_PROVIDER_RES=$fail_msg
        printf "$fail_color$ERROR At least one of the four Storage Providers are required$color_end\n"
        printf "$fail_color$ERROR The supported Storage Providers are Portworx, Openshift Data Foundation, IBM Cloud Storage for ROKS, or IBM Spectrum Fusion/IBM Spectrum Scale Container Native. See https://ibm.biz/storage_consideration_440 for details.$color_end\n"
        STORAGE_PROVIDER_RES=$fail_msg
        startEndSection "Storage Provider"
        return 1
    fi

    # Check the storageFound Array if ibm cloud storage is there, if run the function to check for that storageclass
    if [[ " ${storageFound[*]} " =~ "ibmc" ]]; then
        checkIBMCFileGoldGidStorage
    fi

    # Check the storageFound Array if openshift data foundation was found. If so, run the function to check for the expected storgeclasses
    if [[ " ${storageFound[*]} " =~ "odf" ]]; then
        checkODF $ODF_PODS
    fi

    # Check the storageFound Array if portworx was found. If so, run the function to check for the expected storgeclasses
    if [[ " ${storageFound[*]} " =~ "portworx" ]]; then
        checkPortworx
    fi

    if [[ " ${storageFound[*]} " =~ "ibm-spec" ]]; then
        checkIBMSpectrum
    fi

    # Check if there are any failing configurations, if so we can automatically send a failure result for this check
    if [[ "${storageCheckRes[*]}" =~ "fail" ]]; then
        STORAGE_PROVIDER_RES=$fail_msg
        log $INFO "One or more errors found when checking for Storage Providers."
        startEndSection "Storage Provider"
        return 1
    fi

    # If we did not find any strings with "fail", then we can assume we assume we only have warnings and/or passes. First, check if
    # there are any warnings. If found we can warn the user there was one warning message that was found. Otherwise, show "Pass" for overall 
    # storage check.
    if [[ "${storageCheckRes[*]}" =~ "warn"  ]]; then
        STORAGE_PROVIDER_RES=$warning_msg
        log $INFO "One of more warnings found when checking for Storage Providers."
    else
        STORAGE_PROVIDER_RES=$pass_msg
        log $INFO "No warnings or failures found when checking for Storage Providers."
    fi

    startEndSection "Storage Provider"
    return 0 
}

get_worker_node_list() {
    oc_version=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')

    if [ -z "${all_node_list}" ] ; then
        all_node_list=`${command} get nodes | grep -v NAME | awk '{ print $1 }' | sort -V | tr "\n" ' ' | tr -s ' '`
    fi        
    
    if [ -z ${notop} ] ; then
        top=`${command} ${adm} top nodes`
    fi
    

    for node in ${all_node_list} ; do
        # If node has label indicating it's amd64, then do the following
        if [[ "$oc_version" == *"4.14"* ]]; then
            amd64Check=`${command} get node $node -o jsonpath='{.metadata.labels.kubernetes\.io/arch}'`
            if [[ "${amd64Check}" == "amd64" ]]; then
                ${command} get node $node -o jsonpath='{.metadata.labels}' | fgrep node-role.kubernetes.io/master > /dev/null 2>&1
                if [[ "$?" == "0" ]]; then
                    master_node_count=$((${master_node_count}+1))
                else
                    worker_node_count=$((${worker_node_count}+1))
                fi
                total_nodes=$((${total_nodes}+1))
            else
                log $INFO "Ignoring node ${node} because it is not amd64"
            fi
        else
            describe=`${command} describe node ${node} 2> /dev/null`
            NoSchedule=`echo ${describe} | grep NoSchedule`
            if [ -z "${NoSchedule}" ] ; then
                worker_node_count=$((${worker_node_count}+1))
            else
                master_node_count=$((${master_node_count}+1))
            fi
            total_nodes=$((${total_nodes}+1))
        fi
    done
}

convert_memory_in_MB() {

    local node_mem_raw=$1
    local node_mem_without_unit=$2

    #1 Kibibyte is equal to (2^10 / 10^6) megabytes.
    #https://www.gbmb.org/kib-to-mb
    KiToMB=$(awk "BEGIN{print 2 ^ 10 / 10 ^ 6}")
    
    #1 Mebibyte is equal to (2^20 / 10^6) megabytes.
    #https://www.gbmb.org/mib-to-mb
    MiToMB=$(awk "BEGIN{print 2 ^ 20 / 10 ^ 6}")
    
    #1 Gibibyte is equal to (2^30 / 10^6) megabytes.
    #https://www.gbmb.org/gib-to-mb
    GiToMB=$(awk "BEGIN{print 2 ^ 30 / 10 ^ 6}")

    # One Tebibyte is equal to (2^40 / 10^6) megabytes.
    # https://www.gbmb.org/tib-to-mb
    TiToMB=$(awk "BEGIN{print 2 ^ 40 / 10 ^ 6}")

    # One Pebibyte is equal to (1024 ^ 5 / 1000 ^ 2) megabytes
    # https://www.dataunitconverter.com/pebibyte-to-megabyte/1#how_to_convert
    PiToMB=$(awk "BEGIN{print 1024 ^ 5 / 1000 ^ 2}")

    # One Ei is equal to (1024 ^ 6 / 1000 ^ 2) megabytes
    # https://www.dataunitconverter.com/exbibyte-to-megabyte/1
    EiToMB=$(awk "BEGIN{print 1024 ^ 6 / 1000 ^ 2}")


    #Requested memory unit can be Mi(Mebibyte) or Ki(Kibibyte), or Gi(Gibibytes) which is not the same everytime.
    #Hence we need to convert the given requested memory in MB for calculations.
    # To learn more about the different memory units, see https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
    mem_MB=0
    if [[ "${node_mem_raw}" =~ "Ki" ]] ; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit * $KiToMB}")
    elif [[ "${node_mem_raw}" =~ "Mi" ]] ; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit * $MiToMB}")
    elif [[ "${node_mem_raw}" =~ "Gi" ]] ; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit * $GiToMB}")
    elif [[ "${node_mem_raw}" =~ "m" ]] ; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit / 10 ^ 9 }")
    elif [[ "${node_mem_raw}" =~ ^[0-9]+$ ]] ; then
        # Convert Bytes to MB
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit / 10 ^ 6 }")
    elif [[ "${node_mem_raw}" =~ "Ti" ]]; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit * $TiToMB}")
    elif [[ "${node_mem_raw}" =~ "Pi" ]]; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit * $PiToMB}")
    elif [[ "${node_mem_raw}" =~ "Ei" ]]; then
        mem_MB=$(awk "BEGIN{print $node_mem_without_unit * $EiToMB}")
    else
        unitNotSupported="true"
    fi
}

covert_cpu_unit() {

    local cpu_before_conversion=$1
    
    converted_cpu=0
    if [[ "${cpu_before_conversion}" =~ "m" ]] ; then
        converted_cpu=`echo ${cpu_before_conversion} | sed 's/[^0-9]*//g'`
    else
        converted_cpu=$((${cpu_before_conversion}*1000))
    fi
    
}

calculate_memory_unrequested() {
    
    #https://www.gbmb.org/kib-to-mb
    #1 Kibibyte is equal to (2^10 / 10^6) megabytes.
    KiToMB=$(awk "BEGIN{print 2 ^ 10 / 10 ^ 6}")
    
    #Allocatable raw memory of a node with unit value. eg 30998112Ki
    node_mem_raw_Ki=`echo ${node_resources} | awk '{ print $4 }'`
    node_mem_allocatable_Ki=`echo ${node_mem_raw_Ki} | sed 's/[^0-9]*//g'`

    #Allocatable memory converted in MB
    convert_memory_in_MB $node_mem_raw_Ki $node_mem_allocatable_Ki
    node_mem_allocatable_MB=$mem_MB
    
    #Requested memory for current node eg: 26958Mi or 30998112Ki
    node_mem_request_raw=`echo "${node_describe}" | grep 'memory ' -a | tail -1 | awk '{ print $2 }'`
    node_mem_request_without_unit=`echo ${node_mem_request_raw} | sed 's/[^0-9]*//g'`

    #Requested memory converted to MB
    convert_memory_in_MB $node_mem_request_raw $node_mem_request_without_unit
    node_mem_request_MB=$mem_MB
    
    #Available memory for new install in MB
    node_memory_unrequested_MB=$(awk "BEGIN{print $node_mem_allocatable_MB - $node_mem_request_MB}")

    #Total memory availale for new install
    total_memory_unrequested_MB=$(awk "BEGIN{print $total_memory_unrequested_MB + $node_memory_unrequested_MB}")

}

calculate_cpu_unrequested() {

    #Allocatable raw cpu from node resource
    node_cpu_raw=`echo ${node_resources} | awk '{ print $2 }'`
    
    #Requested cpu resource from node resource
    node_cpu_request=`echo "${node_describe}" | grep 'cpu ' -a | tail -1 | awk '{ print $2 }' `

    covert_cpu_unit $node_cpu_raw
    node_cpu_allocatable=$converted_cpu
    
    covert_cpu_unit $node_cpu_request
    node_cpu_request=$converted_cpu
    
    #Current node cpu resource that is available for anything new to be installed.
    node_cpu_unrequested=$((${node_cpu_allocatable}-${node_cpu_request}))
    
    #Total cpu resource of the cluster that is available for anything new to be installed.
    total_cpu_unrequested=$((${total_cpu_unrequested}+${node_cpu_unrequested}))

}

check_available_cpu_and_memory() {
    
    #Fetch all the nodes for current cluster
    get_worker_node_list

    # If node has label indicating it's amd64, do the calculations
    amd64Check=`${command} get node $node -o jsonpath='{.metadata.labels.kubernetes\.io/arch}'`
    if [[ "$amd64Check" == "amd64" ]]; then
        #For each node calculate cpu and memory resource.
        for node in ${all_node_list} ; do
            node_describe=`${command} describe node ${node}`
            node_resources=`echo "${node_describe}" | grep 'Allocatable' -A 6 -a | grep 'cpu|memory' -a -E | tr "\n" ' ' | tr -s ' '`
            
            #Calculate cpu resource available for each node
            calculate_cpu_unrequested

            #Calculate memory resource available for each node
            calculate_memory_unrequested
        done
    fi

    #100m CPU, 100 milliCPU, and 0.1 CPU are all the same. We calculate the cpu by dropping m hence we need to convert it back to 
    #vCPU = (total_cpu_unrequested / 1000)
    total_cpu_unrequested=$(awk "BEGIN{print $total_cpu_unrequested / 1000}")
    #Converting the floating point to nearest integer.
    total_cpu_unrequested=$( printf "%.0f" $total_cpu_unrequested )
    
    #Converting the memory from MB to GB , 1GB = 1024MB
    total_memory_unrequested_GB=$(awk "BEGIN{print $total_memory_unrequested_MB / 1024}")
    #Converting the floating point to nearest integer
    total_memory_unrequested_GB=$( printf "%.0f" $total_memory_unrequested_GB )
    
}

analyze_resource_display() {

    ## Display for regular install

    # For production sized installs, if nodes are less than or equal to five, set large worker node as fail...
    # If nodes are b/w six and nine, then set as warning
    # If 10 or more, then set to pass
    if [[ $worker_node_count -le 5 ]]; then
        large_worker_node_count_string=`printf "$fail_color $worker_node_count $color_end\n"`
    elif [[ $worker_node_count -ge $NODE_COUNT_LARGE_4_4 ]]; then
        large_worker_node_count_string=`printf "$pass_color $worker_node_count $color_end\n"`
    else
        large_worker_node_count_string=`printf "$warn_color $worker_node_count $color_end\n"`
    fi
    
    if [[ $total_cpu_unrequested -ge $VCPU_LARGE_4_4 ]]; then
        large_total_cpu_unrequested_string=`printf "$pass_color $total_cpu_unrequested $color_end\n"`
    else
        large_total_cpu_unrequested_string=`printf "$fail_color $total_cpu_unrequested $color_end\n"`
    fi

    if [[ $total_memory_unrequested_GB -ge $MEMORY_LARGE_4_4 ]]; then
        large_total_memory_unrequested_GB_string=`printf "$pass_color $total_memory_unrequested_GB $color_end\n"`
    elif [[ $total_memory_unrequested_GB -le 0 && "$unitNotSupported" -eq "true"  ]]; then
        large_total_memory_unrequested_GB_string=`printf "$fail_color DNE $color_end\n"`
    else
        large_total_memory_unrequested_GB_string=`printf "$fail_color $total_memory_unrequested_GB $color_end\n"`
    fi

    if [[ $worker_node_count -ge $NODE_COUNT_SMALL_4_4 ]]; then
        small_worker_node_count_string=`printf "$pass_color $worker_node_count $color_end\n"`
    else
        small_worker_node_count_string=`printf "$fail_color $worker_node_count $color_end\n"`
    fi
    
    if [[ $total_cpu_unrequested -ge $VCPU_SMALL_4_4 ]]; then
        small_total_cpu_unrequested_string=`printf "$pass_color $total_cpu_unrequested $color_end\n"`
    else
        small_total_cpu_unrequested_string=`printf "$fail_color $total_cpu_unrequested $color_end\n"`
    fi
    
    if [[ $total_memory_unrequested_GB -ge $MEMORY_SMALL_4_4 ]]; then
        small_total_memory_unrequested_GB_string=`printf "$pass_color $total_memory_unrequested_GB $color_end\n"`
    elif [[ $total_memory_unrequested_GB -le 0 && "$unitNotSupported" -eq "true"  ]]; then
        small_total_memory_unrequested_GB_string=`printf "$fail_color DNE $color_end\n"`
    else
        small_total_memory_unrequested_GB_string=`printf "$fail_color $total_memory_unrequested_GB $color_end\n"`
    fi

}

checkSmallOrLargeProfileInstall() {

    largeProfileNodeCheck=""
    
    echo
    startEndSection "Small or Large Profile Install Resources"
    log $INFO "Checking for cluster resources"
    echo
    check_available_cpu_and_memory
    
    analyze_resource_display
    
    log $INFO "==================================Resource Summary====================================================="
    header=`printf "   %40s   |      %s      |     %s" "Nodes" "vCPU" "Memory(GB)"`
    log $INFO "${header}"
    string=`printf "Small profile(available/required)  [ %s/ %s ]   [ %s/ %s ]       [ %s/ %s ]" "$small_worker_node_count_string" "$NODE_COUNT_SMALL_4_4" "$small_total_cpu_unrequested_string" "$VCPU_SMALL_4_4" "$small_total_memory_unrequested_GB_string" "$MEMORY_SMALL_4_4"`
    log $INFO "${string}"
    string=`printf "Large profile(available/required)  [ %s/ %s ]   [ %s/ %s ]       [ %s/ %s ]" "$large_worker_node_count_string" "$NODE_COUNT_LARGE_4_4" "$large_total_cpu_unrequested_string" "$VCPU_LARGE_4_4" "$large_total_memory_unrequested_GB_string" "$MEMORY_LARGE_4_4"`
    log $INFO "${string}"
    
    # Script need to output a message if memory cant be calculated. This script only supports Ki, Mi, Gi, Ti, Ei, Pi, bytes, and m.
    if [[ "$unitNotSupported" == "true" ]]; then
        log $WARNING "Cannot calculate memory because allocatable memory is using a unit that is not recognizable. This tool supports Ki, Gi, Mi, Ti, Ei, Pi, Bytes, and m"
    fi

    log $INFO "==================================Resource Summary====================================================="

    if [[ $worker_node_count -le 5 ]]; then
        largeProfileNodeCheck="false"
    elif [[ $worker_node_count -ge $NODE_COUNT_LARGE_4_4 ]]; then
        largeProfileNodeCheck="true"
    else
        largeProfileNodeCheck="warn"
    fi
    
    if [[ ("$largeProfileNodeCheck" == "true" ) && ($total_cpu_unrequested -ge $VCPU_LARGE_4_4) && ($total_memory_unrequested_GB -ge $MEMORY_LARGE_4_4)  ]] ; then
        log $INFO "Cluster currently has resources available to create a large profile of Cloud Pak for AIOps"
    elif [[ $worker_node_count -ge $NODE_COUNT_SMALL_4_4 && ($total_cpu_unrequested -ge $VCPU_SMALL_4_4) && ($total_memory_unrequested_GB -ge $MEMORY_SMALL_4_4) ]] ; then
        log $INFO "Cluster currently has resources available to create a small profile of Cloud Pak for AIOps"
    else
        log $ERROR "Cluster does not have required resources available to install Cloud Pak for AIOps."
        echo
        PROFILE_RES=$fail_msg
        startEndSection "Small or Large Profile Install Resources"
        return 1
    fi

    if [[ "$largeProfileNodeCheck" == "warn" ]]; then
        echo
        printf "$warn_color$WARNING 6-9 worker nodes are adequate for a production deployment, but for resilience IBM recommends at least 10 worker nodes to enable the deployment to better withstand a worker node being unavailable. $color_end\n"
        PROFILE_RES=$warning_msg
        startEndSection "Small or Large Profile Install Resources"
        return 0
    fi

    PROFILE_RES=$pass_msg
    startEndSection "Small or Large Profile Install Resources"
}

function printTable() {
    local name=$1
    local namespace=$2

    echo
    paste <(printf '%s\n' CLUSTERSERVICEVERSION "${name}") \
          <(printf '%s\n' NAMESPACE "${namespace}") \
    | column -ts $'\t'
    echo
}

function checkIfCertManagerPresent() {

    echo
    startEndSection "Cert Manager Check"
    log $INFO "Checking for Cert Manager operator"
    echo

    text=$(oc get csv -A --no-headers=true -o=custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace,PHASE:.status.phase' | grep "cert-manager")
    result=$?
    if [[ "${result}" == "1" ]]; then
        log $ERROR "Cluster does not have a cert-manager operator installed"
        CERTMANAGER_PRESENT=$fail_msg
        return 1
    fi

    name=$(echo $text | awk '{print $1}')
    namespace=$(echo $text | awk '{print $2}')
    phase=$(echo $text | awk '{print $3}')
    if [[ "${phase}" == "Succeeded" ]]; then
        CERTMANAGER_PRESENT=$pass_msg
        log $INFO "Successfully functioning cert-manager found."
    elif [[ "${phase}" == "Pending" ]]; then
        CERTMANAGER_PRESENT=$pass_msg
        log $INFO "Pending cert-manager found."
        printTable $name $namespace
        startEndSection "Cert Manager Check"
        return 1
    else
        CERTMANAGER_PRESENT=$fail_msg
        log $ERROR "Unsuccessfully installed cert-manager found."
        printTable $name $namespace
        startEndSection "Cert Manager Check"
        return 1
    fi

    printTable $name $namespace
    startEndSection "Cert Manager Check"
    return 0
}

function checkIfLicensingPresent() {

    echo
    startEndSection "Licensing Service Operator Check"
    log $INFO "Checking for Licensing Service operator"
    echo

    text=$(oc get csv -A --no-headers=true -o=custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace,PHASE:.status.phase' | grep "licensing-operator")
    result=$?
    if [[ "${result}" == "1" ]]; then
        log $ERROR "Cluster does not have the licensing service operator installed"
        LICENSING_PRESENT=$fail_msg
        return 1
    fi

    name=$(echo $text | awk '{print $1}')
    namespace=$(echo $text | awk '{print $2}')
    phase=$(echo $text | awk '{print $3}')
    if [[ "${phase}" == "Succeeded" ]]; then
        LICENSING_PRESENT=$pass_msg
        log $INFO "Successfully functioning licensing service operator found."
    elif [[ "${phase}" == "Pending" ]]; then
        LICENSING_PRESENT=$pass_msg
        log $INFO "Pending licensing service operator found."
        printTable $name $namespace
        startEndSection "Licensing Service Operator Check"
        return 1
    else
        LICENSING_PRESENT=$fail_msg
        log $ERROR "Unsuccessfully installed licensing service operator found."
        printTable $name $namespace
        startEndSection "Licensing Service Operator Check"
        return 1
    fi

    printTable $name $namespace
    startEndSection "Licensing Service Operator Check"
    return 0
}

showSummary() {

    echo
    echo
    startEndSection "Prerequisite Checker Tool Summary"
    string=`printf "      [ %s ] Openshift Container Platform Version Check " "${OCP_VER_RES}"`
    printf "${string}\n"
    string=`printf "      [ %s ] Entitlement Pull Secret" "${PS_RES}"`
    printf "${string}\n"
    string=`printf "      [ %s ] Storage Provider\n" "${STORAGE_PROVIDER_RES}"`
    printf "${string}\n"
    string=`printf "      [ %s ] Small or Large Profile Install Resources" "${PROFILE_RES}"`
    printf "${string}\n"
    string=`printf "      [ %s ] Cert Manager Operator Installed" "${CERTMANAGER_PRESENT}"`
    printf "${string}\n"
    string=`printf "      [ %s ] Licensing Service Operator Installed" "${LICENSING_PRESENT}"`
    printf "${string}\n"
    startEndSection "Prerequisite Checker Tool Summary"
}

startEndSection() {
    section=$1
    log $INFO "=================================${section}================================="
}

function main {
    initialize

    fail_found=0
    checkOCPVersion || fail_found=1
    checkEntitlementSecret || fail_found=1
    checkStorage || fail_found=1
    checkSmallOrLargeProfileInstall || fail_found=1
    checkIfCertManagerPresent || fail_found=1
    checkIfLicensingPresent || fail_found=1

    showSummary

    return $fail_found
}

main || exit 1