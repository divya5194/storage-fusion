#!/bin/bash

##############################################################################
#Script Name	: preupgrade_healthcheck.sh
#Description	: Utility to run healthcheck for IBM Storage Fusion HCI system
#Args       	:
#Author       	:Anshu Garg,Divya Jain
#Email         	:ganshug@gmail.com, divya.jn5194@gmail.com
##############################################################################

##############################################################################
# This utility will run a healthcheck on IBM Storage Fusion HCI system
# Execute it from a bash shell where you have logged into HCI OpenShift API
# Ensure jq is installed on that system
# It is to be used for only online/connected installs of HCI
# It checks:
# API accessibility
# access from nodes to Quay.io and IBM registries (icr.io and cp.icr.io)
# pull access from one of the node for OCP release image and IDF entitlement validation image
# machine config pool
# nodes status
# cluster operators
# catalog sources
# Fusion operators
# services health
# Scale
# Backup and Restore
# VirtualMachine PVCs accessmode
# Nodes hardware health
# Switch, vlan and link health

# Execute as
# ./preupgrade_healthcheck.sh
##############################################################################

CHECK_PASS='  ✅'
CHECK_FAIL='  ❌'
CHECK_UNKNOW='  ⏳'
PADDING_1='   '
PADDING_2='      '
REPORT=$(pwd)/preupgrade_healthcheck_report.log
TEMP_MMHEALTH_FILE=$(pwd)/tmp_health.log
DISCONNECTEDINSTALL=no
PROXYINSTALL=no
OCPRELEASE_IMAGE="ocp-release@sha256:bb7e12e9dd638f584fee587b6fae07c29100143ad5428560f114df11704627fa"
QUAY=quay.io
QUAYPATH="$QUAY/openshift-release-dev"
IBMOPENREG="icr.io"
ISFCATALOG_PATH="$IBMOPENREG/cpopen"
ISFCATALOG_IMAGE="2.5.2-linux.amd64"
IBMENTITLEDREG="cp.icr.io"
ISFENTITLEMENT_PATH="$IBMENTITLEDREG/cp/isf"
ISFENTITLEMENT_IMAGE="isf-validate-entitlement@sha256:1a0dbf7c537f02dc0091e3abebae0ccac83da6aa147529f5de49af0f23cd9e8e"
CONTROLNODE=""
SCALENS="ibm-spectrum-scale"
SCALEDNSNS="ibm-spectrum-scale-dns"
SCALEOPNS="ibm-spectrum-scale-operator"
SCALECSINS="ibm-spectrum-scale-csi"
FUSIONNS="ibm-spectrum-fusion-ns"
COMPUTEDRAINTAINTKEY="isf.compute.fusion.io/drain"
NOSCHEDULEEFFECT="NoSchedule"

#exec >>(tee ${REPORT}) 2>&1

function print_header() {
    echo "======================================================================================"
    echo "Started healthcheck for IBM Storage Fusion HCI cluster at $(date +'%F %z %r')"
    echo "======================================================================================"
}

function print_footer() {
    echo ""
    echo "========================================================================================"
    echo "Healthcheck for IBM Storage Fusion HCI cluster completed at $(date +'%F %z %r')"
    echo "========================================================================================"
}

function print_section() {
    echo ""
    echo "======================================================================================"
    echo "			****** $1 ******"
    echo "======================================================================================"
    echo ""
}

function print_subsection() {
    echo ""
    echo "======================================================================================"
    echo ""
}


function print() {
        case "$1" in
                "info")
                        echo "INFO: $2";;
                "error")
                        echo "ERROR: $2";;
                "warn")
                        echo "WARN: $2";;
                "debug")
                        echo "DEBUG: $2";;
		"*")
			echo "$2";;
	esac
}


# Verify we are able to access OCP API and can execute oc commands
function verify_api_access() {
	print info "Verify Red Hat OpenShift API access."
	oc get clusterversion >/dev/null
	if [ $? -ne 0 ]; then
        	print error "${CHECK_FAIL} Red Hat OpenShift API is inaccessible. Rest of the check can not be executed. Please login to OCP api before executing script."
		exit 1
        else
        	print info "${CHECK_PASS} Red Hat OpenShift API is accessible."
	fi
}

# Verify Red Hat OpenShift cluster operators health
function verify_clusteroperators_status () {
	print info "Verify Red Hat OpenShift cluster operators health."
	notavailablecocount=$(oc get co)
        unhealthy=0
        rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
        while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get co|grep -v NAME)"
        while IFS= read -r line
        do
                comp=$(echo $line|awk '{print $1}')
                available=$(echo $line|awk '{print $3}')	# Possible values True|False
                progressing=$(echo $line|awk '{print $4}')	# Possible values True|False
                degraded=$(echo $line|awk '{print $5}')		# Possible values True|False
                if [[ "${available}" == False || "${progressing}" == True || "${degraded}" == True ]]
		then
                        print error "${CHECK_FAIL} ${failed} Cluster operator $comp is not healthy or/and ready."
			print error "${CHECK_FAIL} $line"
                        unhealthy=1
                fi
        done <<< $(cat "${TEMP_MMHEALTH_FILE}")
        if [ $unhealthy  -eq 0 ]; then
                print info "${CHECK_PASS} All Red Hat OpenShift cluster operators are healthy."
        fi
        rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

# Verify Red Hat OpenShift nodes status
function verify_nodes_status() {
	print info "Verify Red Hat OpenShift nodes status."
	notreadynodescount=$(oc get nodes|egrep -i 'NotReady|Scheduling'|wc -l)
	if [ "${notreadynodescount}" -ne 0 ]; then
		print error "${CHECK_FAIL} Following nodes are not Ready."
		oc get nodes|egrep -i 'NotReady|Scheduling'
		print error "${CHECK_FAIL} All Red Hat OpenShift nodes are not Ready."
	else
		print info "${CHECK_PASS} All Red Hat OpenShift nodes are Ready."
        fi

}

# Verify no ongoing updates on nodes as part of mco
function verify_mcp() {
	print info "Verify machine config pools are updated."
	#NAME     CONFIG   UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT
	inprogress=0
	degraded=0
	notready=0
	notupdated=0
	winprogress=0
	wdegraded=0
	wnotready=0
	wnotupdated=0
	computemcp=$(oc get mcp worker|grep -v READYMACHINECOUNT)
	controlmcp=$(oc get mcp master|grep -v READYMACHINECOUNT)
	computecount=$(oc get nodes |grep compute|wc -l)
	controlcount=$(oc get nodes |grep control|wc -l)
	degcompute=$(echo $computemcp|awk '{print $5}')
	readycompute=$(echo $computemcp|awk '{print $7}')
	updatedcompute=$(echo $computemcp|awk '{print $8}')
	inprogresscompute=$(echo $computemcp|awk '{print $4}')
	degcontrol=$(echo $controlmcp|awk '{print $5}')
	inprogresscontrol=$(echo $controlmcp|awk '{print $4}')
	readycontrol=$(echo $controlmcp|awk '{print $7}')
	updatedcontrol=$(echo $controlmcp|awk '{print $8}')
	if [[ $degcompute -ne 0 ]]; then
		print error "${CHECK_FAIL}  $degcompute compute nodes are degraded."
		wdegraded=1
	fi
	if [[ $inprogresscompute -ne 0 ]]; then
		print error "${CHECK_UNKNOW}  $inprogresscompute compute nodes are updating."
		winprogress=1
	fi
	if [[ $readycompute -ne $computecount ]]; then
		print error "${CHECK_FAIL}  $readycompute compute nodes are not ready."
		wnotready=1
	fi
	if [[ $updatedcompute -ne $computecount ]]; then
		print error "${CHECK_FAIL}  $updatedcompute compute nodes are not updated."
		wnotupdated=1
	fi
	if [[ $wnotupdated -eq 1 || $wnotready -eq 1 || $winprogress -eq 1 || $wdegraded -eq 1 ]]; then
		print error "${CHECK_FAIL} $(oc get nodes|grep compute)"
	fi

	print_subsection
	# Check control mcp
	if [[ $degcontrol -ne 0 ]]; then
		print error "${CHECK_FAIL}  $degcontrol control nodes are degraded."
		degraded=1
	fi
	if [[ $inprogresscontrol -ne 0 ]]; then
		print error "${CHECK_UNKNOW}  $inprogresscontrol control nodes are updating."
		inprogress=1
	fi
	if [[ $readycontrol -ne $controlcount ]]; then
		print error "${CHECK_FAIL}  $readycontrol control nodes are not ready."
		notready=1
	fi
	if [[ $updatedcontrol -ne $controlcount ]]; then
		print error "${CHECK_FAIL}  $updatedcontrol control nodes are not updated."
		notupdated=1
	fi
	if [[ $notupdated -eq 1 || $notready -eq 1 || $inprogress -eq 1 || $degraded -eq 1 ]]; then
		print error "${CHECK_FAIL} $(oc get nodes|grep control)"
	fi
	if [[ $notready -eq 0 && $inprogress -eq 0 && $degraded -eq 0 && $notupdated -eq 0 && $wnotupdated -eq 0 && $wnotready -eq 0 && $winprogress -eq 0 && $wdegraded -eq 0 ]]; then
		print info "${CHECK_PASS} All machine configuration pools are upto date."
	fi
}

# Verify catalogsources
# Failed catalog impact any and every operator install in cluster so all catalaog sources including customer's own catalogsources must be healthy
function verify_catsrc() {
	print info "Verify catalog sources health in cluster."
        unhealthy=0
	# oc get catsrc -A
	#NAMESPACE               NAME
	rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
        while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get catsrc -A |grep -v NAME)"
        while IFS= read -r line
        do
                name=$(echo $line|awk '{print $2}')
                ns=$(echo $line|awk '{print $1}')
                state=$(oc get catsrc $name -n $ns -o yaml|grep lastObservedState |grep -v "f:"|awk '{print $2}')
                if [[ "$state" != "READY" ]]; then
                        print error "${CHECK_FAIL} catalog source ${name} in namespace $ns is not ready."
                        unhealthy=1
                fi
        done <<< $(cat "${TEMP_MMHEALTH_FILE}")
	if [[ ${unhealthy} -eq 0 ]]; then
		print info "${CHECK_PASS} All catalog sources are ready."
	fi
}

# Verify status of Scale daemon pods
function verify_scale_daemon_pods_status() {
        print info "Verify IBM Storage Scale daemon pods status."
	fail=0
        running=$(oc get daemons ibm-spectrum-scale -n $SCALENS -ojson | jq -r '.status.podsStatus'|grep running| awk '{print $2}'|cut -d '"' -f 2)
        terminating=$(oc get daemons ibm-spectrum-scale -n $SCALENS -ojson | jq -r '.status.podsStatus'|grep terminating| awk '{print $2}'|cut -d '"' -f 2)
        starting=$(oc get daemons ibm-spectrum-scale -n $SCALENS -ojson | jq -r '.status.podsStatus'|grep starting| awk '{print $2}'|cut -d '"' -f 2)
        waitingForDelete=$(oc get daemons ibm-spectrum-scale -n $SCALENS -ojson | jq -r '.status.podsStatus'|grep waitingForDelete| awk '{print $2}'|cut -d '"' -f 2)
        unknown=$(oc get daemons ibm-spectrum-scale -n $SCALENS -ojson | jq -r '.status.podsStatus'|grep unknown| awk '{print $2}'|cut -d '"' -f 2)
        if [ "${terminating}" -ne 0 ]; then
                print error "${CHECK_FAIL} ${terminating} daemons are in terminating state."
		fail=1
        fi
        if [ "${starting}" -ne 0 ]; then
                print error "${CHECK_UNKNOW} ${starting} daemons are in starting state."
		fail=1
        fi
        if [ "${waitingForDelete}" -ne 0 ]; then
                print error "${CHECK_FAIL} ${waitingForDelete} daemons are in waitingForDelete state."
		fail=1
        fi
        if [ "${unknown}" -ne 0 ]; then
                print error "${CHECK_FAIL} ${unknown} daemons are in unknown state."
		fail=1
        fi
	if [ $fail -eq 0 ]; then
                print info "${CHECK_PASS} All of IBM Storage Scale daemon pods are healthy."
        fi
}

# Verify scale operator pod
function verify_scale_operator_pods () {
	print info "Verify IBM Storage Scale operator pod status."
	oc -n $SCALEOPNS get pods|grep "Running" >/dev/null
	if [[ $? -ne 0 ]]; then
		print error "${CHECK_UNKNOW} IBM Storage Scale operator is not healthy."
	else
		print info "${CHECK_PASS} IBM Storage Scale operator is healthy."
	fi
}

# Verify scale dns pods
function verify_scale_dns_pods () {
	print info "Verify IBM Storage Scale dns pods status."
	oc -n $SCALEDNSNS get pods|grep "Running" >/dev/null
	if [[ $? -ne 0 ]]; then
		print error "${CHECK_UNKNOW} All IBM Storage Scale dns pods are not healthy."
	else
		print info "${CHECK_PASS} All IBM Storage Scale dns pods are healthy."
	fi
}

# Verify scale csi pods
function verify_scale_csi_pods () {
	print info "Verify IBM Storage Scale csi pods status."
	oc -n $SCALECSINS get pods|grep "Running" >/dev/null
	if [[ $? -ne 0 ]]; then
		print error "${CHECK_UNKNOW} All IBM Storage Scale CSI pods are not healthy."
	else
		print info "${CHECK_PASS} All IBM Storage Scale CSI pods are healthy."
	fi
}

# Get Scale health summary
function verify_mmhealth_summary() {
	print info "Verify IBM Storage Scale health"
	unhealthy=0
	rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
	nodename=$(oc get nodes |grep 'control'|grep 'Ready'|head -1|awk '{print $1}'|cut -d"." -f 1)
	while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc -n $SCALENS rsh $nodename mmhealth cluster show|egrep 'NODE|GPFS|NETWORK|FILESYSTEM|DISK|FILESYSMGR|GUI|NATIVE_RAID|PERFMON|THRESHOLD|STRETCHCLUSTER')"
	while IFS= read -r line
	do
		comp=$(echo $line|awk '{print $1}')
		failed=$(echo $line|awk '{print $3}')
		degraded=$(echo $line|awk '{print $4}')
		if [ ${failed} -ne 0 ]; then
			print error "${CHECK_FAIL} ${failed} failed $comp found."
			unhealthy=1
		fi
		if [ ${degraded} -ne 0 ]; then
                        print error "${CHECK_FAIL} ${degraded} degraded $comp found."
			unhealthy=1
		fi
	done <<< $(cat "${TEMP_MMHEALTH_FILE}")
	if [ $unhealthy  -eq 0 ]; then
		print info "${CHECK_PASS} All of IBM Storage Scale components are healthy."
	else
		print error "${CHECK_UNKNOW} health summary:"
		oc -n $SCALENS rsh $nodename mmhealth cluster show
	fi
	rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

# Get Scale detailed status
function verify_mmhealth_details() {
        print info "Verify IBM Storage Scale health"
        unhealthy=0
        rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
        while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc rsh control-1-ru2 mmhealth node show -N all)"
        while IFS= read -r line
        do
                comp=$(echo $line|awk '{print $1}')
                failed=$(echo $line|awk '{print $3}')
                degraded=$(echo $line|awk '{print $4}')
                if [ ${failed} -ne 0 ]; then
                        print error "${CHECK_FAIL} ${failed} failed $comp found."
                        unhealthy=1
                fi
                if [ ${degraded} -ne 0 ]; then
                        print error "${CHECK_FAIL} ${degraded} degraded $comp found."
                        unhealthy=1
                fi
        done <<< $(cat "${TEMP_MMHEALTH_FILE}")
        if [ $unhealthy  -eq 0 ]; then
                print info "${CHECK_PASS} All of IBM Storage Scale components are healthy."
        else
                print error "${CHECK_FAIL} health summary:"
                oc rsh control-1-ru2 mmhealth cluster show
        fi
        rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

# Verify Scale health
function verify_scale_health () {
        oc get project |grep ibm-spectrum-scale-operator > /dev/null
        if [[ $? -ne 0 ]]; then
                print info "${CHECK_UNKNOW} ibm-spectrum-scale-operator project does not exist. It is possible that service is not installed or failed at very early stage."
                return 0
        fi
	verify_scale_operator_pods
	print_subsection
	verify_scale_daemon_pods_status
	print_subsection
	verify_scale_dns_pods
	print_subsection
	verify_scale_csi_pods
	print_subsection
	verify_mmhealth_summary
	#print_subsection
	#verify_mmhealth_details
}

# Get Fusion operator health
function verify_fusion_health() {
	print info "Verify IBM Storage Fusion health."
	csvhealth=$(oc get csv -n ibm-spectrum-fusion-ns|grep isf-operator|grep Succeeded)
	if [ $? -ne 0 ]; then
		print error "${CHECK_FAIL} IBM Storage Fusion operator is not healthy."
		print error "${CHECK_FAIL} $(oc get csv -n ibm-spectrum-fusion-ns|grep isf-operator)"
	fi
}

# Get data cataloging status
function verify_dcs_health () {
	print info "Verify Data classification service health."
	# check operators health
        unhealthy=0
        oc get project |grep ibm-data-cataloging > /dev/null
        if [[ $? -ne 0 ]]; then
                print info "${CHECK_UNKNOW} ibm-data-cataloging project does not exist. It is possible that service is not installed or failed at very early stage."
                return 0
        fi
        notsuccesscount=$(oc get csv -n ibm-data-cataloging|egrep -v 'Succ|NAME'|wc -l)
		if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} operators for DCS are degraded."
                unhealthy=1
                print error "${CHECK_UNKNOW} Here are failed operators. Use \"oc describe csv <csv name> -n ibm-data-cataloging\" to get more details about failure."
                oc get csv -n ibm-data-cataloging|egrep -v 'Succ|NAME'
	else
                print info "${CHECK_PASS} All operators for DCS are healthy."
        fi

        print_subsection
        # check pods health
        unhealthy=0
        notsuccesscount=$(oc get po -n ibm-data-cataloging |egrep -v 'Running|Completed|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} pods for DCS are not running."
                unhealthy=1
                print error "${CHECK_FAIL} Here are failed pods:"
                oc get pods -n ibm-data-cataloging|egrep -v 'Running|Completed|NAME'
        else
                print info "${CHECK_PASS} All pods for DCS  are healthy."
        fi

        print_subsection
        # check pvc health
        unhealthy=0
        notsuccesscount=$(oc get pvc -n ibm-data-cataloging|egrep -v 'Bound|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} PVCs for DCS are not bound."
                unhealthy=1
                print error "${CHECK_FAIL} List of unbound PVCs:"
                oc get pvc -n ibm-data-cataloging|egrep -v 'Bound|NAME'
        else
                print info "${CHECK_PASS} All PVCs for DCS are bound."
        fi
}

# Get data protection operators health
function verify_br_health() {
	print info "Verify IBM Storage Fusion Data protection health."

	# check operators health
	unhealthy=0
	oc get project |grep ibm-backup-restore > /dev/null
	if [[ $? -ne 0 ]]; then
		print info "${CHECK_UNKNOW} ibm-backup-restore project does not exist. It is possible that service is not installed or failed at very early stage."
		return 0
	fi
	notsuccesscount=$(oc get csv -n ibm-backup-restore|egrep -v 'Succ|NAME'|wc -l)
	if [ ${notsuccesscount} -ne 0 ]; then
		print error "${CHECK_FAIL} ${notsuccesscount} operators for data protection are degraded."
	        unhealthy=1
		print error "${CHECK_UNKNOW} Here are failed operators. Use \"oc describe csv <csv name> -n ibm-backup-restore\" to get more details about failure."
		oc get csv -n ibm-backup-restore|egrep -v 'Succ|NAME'
        else
		print info "${CHECK_PASS} All operators for data protection are healthy."
	fi

	print_subsection
	# check pods health
	unhealthy=0
	notsuccesscount=$(oc get po -n ibm-backup-restore|egrep -v 'Running|Completed|NAME'|wc -l)
	if [ ${notsuccesscount} -ne 0 ]; then
		print error "${CHECK_FAIL} ${notsuccesscount} pods for data protection are not running."
	        unhealthy=1
		print error "${CHECK_FAIL} Here are failed pods:"
		oc get pods -n ibm-backup-restore|egrep -v 'Running|Completed|NAME'
        else
		print info "${CHECK_PASS} All pods for data protection are healthy."
	fi

	print_subsection
        # check pvc health
	unhealthy=0
        notsuccesscount=$(oc get pvc -n ibm-backup-restore|egrep -v 'Bound|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} PVCs for data protection are not bound."
                unhealthy=1
                print error "${CHECK_FAIL} List of unbound PVCs:"
                oc get pvc -n ibm-backup-restore|egrep -v 'Bound|NAME'
        else
                print info "${CHECK_PASS} All PVCs for data protection are bound."
        fi

}

# Get Legacy SPP service health
function verify_spp_health() {
        print info "Verify IBM Storage Fusion legacy SPP health."

        # check namespace for spp server
        oc get project |grep ibm-spectrum-protect-plus-ns > /dev/null
        if [[ $? -ne 0 ]]; then
                print info "${CHECK_UNKNOW} ibm-spectrum-protect-plus-ns project does not exist. It is possible that service is not installed or failed at very early stage."
                return 0
        fi

        # check pods health
        unhealthy=0
        notsuccesscount=$(oc get po -n ibm-spectrum-protect-plus-ns|egrep -v 'Running|Completed|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} pods for SPP server are not running."
                unhealthy=1
                print error "${CHECK_FAIL} Here are failed pods:"
                oc get pods -n ibm-spectrum-protect-plus-ns|egrep -v 'Running|Completed|NAME'
        else
                print info "${CHECK_PASS} All pods for SPP server are healthy."
        fi

        print_subsection
        # check pvc health
        unhealthy=0
        notsuccesscount=$(oc get pvc -n ibm-spectrum-protect-plus-ns|egrep -v 'Bound|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} PVCs for SPP server are not bound."
                unhealthy=1
                print error "${CHECK_FAIL} List of unbound PVCs:"
                oc get pvc -n ibm-spectrum-protect-plus-ns|egrep -v 'Bound|NAME'
	else
		print info "${CHECK_PASS} All PVCs for SPP server are bound."
	fi

	print_subsection
        # check namespace for spp agent
        oc get project |grep baas > /dev/null
        if [[ $? -ne 0 ]]; then
                print info "${CHECK_UNKNOW} baas project does not exist. It is possible that service is not installed or failed at very early stage."
                return 0
        fi

	# check pods health
        unhealthy=0
        notsuccesscount=$(oc get po -n baas|egrep -v 'Running|Completed|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} pods for SPP agent are not running."
                unhealthy=1
                print error "${CHECK_FAIL} Here are failed pods:"
                oc get pods -n baas|egrep -v 'Running|Completed|NAME'
        else
                print info "${CHECK_PASS} All pods for SPP agent are healthy."
        fi

	print_subsection
        # check pvc health
        unhealthy=0
        notsuccesscount=$(oc get pvc -n baas|egrep -v 'Bound|NAME'|wc -l)
        if [ ${notsuccesscount} -ne 0 ]; then
                print error "${CHECK_FAIL} ${notsuccesscount} PVCs for SPP agent are not bound."
                unhealthy=1
                print error "${CHECK_FAIL} List of unbound PVCs:"
                oc get pvc -n baas|egrep -v 'Bound|NAME'
        else
                print info "${CHECK_PASS} All PVCs for SPP agent are bound."
        fi
}


# Utility to check if it is disconnected install
function isDisconnectedDeployment () {
        isoffline=$(oc -n ibm-spectrum-fusion-ns get secret userconfig-secret -o json | jq '.data."userconfig_secret.json"'|cut -d '"' -f 2|base64 -d|grep isPrivateRegistry)
        if [ $? -ne 0 ]; then
		DISCONNECTEDINSTALL=yes
	fi
}

# Utility to check if it is proxy install
function isProxyDeployment () {
        isproxy=$(oc -n ibm-spectrum-fusion-ns get secret userconfig-secret -o json | jq '.data."userconfig_secret.json"'|cut -d '"' -f 2|base64 -d|grep isProxy)
        if [ $? -ne 0 ]; then
		PROXYINSTALL=yes
	fi
}

# Get one of control node name (ready)
function getReadyControlNode() {
	CONTROLNODE=$(oc get nodes | grep -vE 'NAME|NotReady|Scheduling' | grep 'master' | head -1|awk '{print $1}')
}

# Verify quay access
function isQuayAccessible () {
	getReadyControlNode
	oc debug nodes/$CONTROLNODE -- chroot /host curl https://$QUAY|grep "Quay " > /dev/null
	if [[ $? -ne 0 ]]; then
		print error "${CHECK_FAIL} $QUAY is not accessible."
	else
		print info "${CHECK_PASS} $QUAY is accessible."
	fi
}

# Verify ibm registry access
function isIBMRegistryAccessible () {
	getReadyControlNode
	oc debug nodes/$CONTROLNODE -- chroot /host curl https://$IBMENTITLEDREG |grep "Connection timed out" > /dev/null
	if [[ $? -ne 0 ]]; then
                print info "${CHECK_PASS} $IBMENTITLEDREG is accessible."
	else
                print error "${CHECK_FAIL} $IBMENTITLEDREG is not accessible."
	fi
	print_subsection
	oc debug nodes/$CONTROLNODE -- chroot /host curl https://$IBMOPENREG|grep "Connection timed out" > /dev/null
	if [[ $? -ne 0 ]]; then
		print info "${CHECK_PASS} $IBMOPENREG is accessible."
        else
		print error "${CHECK_FAIL} $IBMOPENREG is not accessible."
	fi
}

# Verify registry accesses
function areRegistriesAccessible () {
	isQuayAccessible
	print_subsection
	isIBMRegistryAccessible
}

# Verify registry can pull isf images
function canPullIsfImage() {
	getReadyControlNode
	oc debug nodes/$CONTROLNODE -- chroot /host podman pull --authfile /var/lib/kubelet/config.json "$ISFENTITLEMENT_PATH/$ISFENTITLEMENT_IMAGE" |grep "Writing manifest"
	if [[ $? -ne 0 ]]; then
                print error "${CHECK_FAIL} unable to pull image from IBM registry."
        else
                print info "${CHECK_PASS} successfully able to pull ISF images."
        fi
}

# Verify registry can pull isf images
function canPullOCPImage () {
	getReadyControlNode
	oc debug nodes/$CONTROLNODE -- chroot /host podman pull --authfile /var/lib/kubelet/config.json "$QUAYPATH/$OCPRELEASE_IMAGE" |grep "Writing manifest"
	if [[ $? -ne 0 ]]; then
                print error "${CHECK_FAIL} unable to pull image from OpenShift quay.io."
	else
                print info "${CHECK_PASS} successfully able to pull image from OpenShift quay.io."
	fi
}

# Verify images can be pulled, auth is good
function isAuthCorrect () {
	canPullIsfImage
	print_subsection
	canPullOCPImage
}


# Get Virtual machines
# Sample VMS:
#NAMESPACE                 NAME                            AGE     STATUS    READY
#clusters-devcluster-414   devcluster-414-598f1ac6-nfmtd   3d23h   Running   True
#clusters-scale-414        scale-414-7eec1c0e-n9gmj        2d15h   Running   True
function get_virtual_machines () {
  oc get virtualmachine -A 2>&1 >> /dev/null
  if [[ $? -ne 0 ]]; then
    print info "${CHECK_PASS} There are no virtual machines on this cluster, so there is no need to continue this check."
    return 0
  fi

	nonMigratableVM=0
	#vms=$(oc get virtualmachine -A|awk '{print $1 $2}')
	#echo $vm
	#echo "ns:vm:dvName:volClaim:Access mode" |  column -t -s ':'
	rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
	while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get virtualmachine -A |grep -v NAME |awk '{print $1,$2}')"
  while IFS= read -r line
    do
      ns=$(echo $line |awk '{print $1}')
      vm=$(echo $line |awk '{print $2}')
      dvName=$(oc get virtualmachine -n $ns  $vm -o json|jq '.spec.template.spec.volumes[0].dataVolume.name' | tr -d '"')
      volClaim=$(oc get datavolume -n $ns  $dvName -o json| jq '.status.claimName' | tr -d '"')
      am=$(oc -n $ns get pvc $volClaim  -o json|jq '.spec.accessModes[]' | tr -d '"' )
      echo $am|grep -q "ReadWriteMany"
      if [[ $? -ne 0 ]]; then
        nonMigratableVM=$nonMigratableVM+1
        if [[ $nonMigratableVM -eq 1 ]]; then
          print info "VMs that do not use ReadWriteMany access mode for PVC can not be evicted."
        fi
        print error "${CHECK_FAIL} Non-migratable VM: $vm in namespace $ns."
      fi
    done < ${TEMP_MMHEALTH_FILE}
	if [[ $nonMigratableVM -eq 0 ]]; then
		print info "${CHECK_PASS} All vms are migratable."
	fi
}

# Verify VMs are livemigratable
# If VMs are not live migratable then all drains will fail unless VMs are deleted manually
function verify_livemigratable_vms() {
	get_virtual_machines
}

function verify_node_taints(){
  print info "Verify if any node is under fusion maintenance"
  taint_used=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get nodes --no-headers |awk '{print $1}')"
  while IFS= read -r line
  do
    taintkey=$(oc get node $line -o json | jq -r '.spec.taints[]?|.key')
    taintval=$(oc get node $line -o json | jq -r '.spec.taints[]?|.effect')
    if [[ "${taintkey}" == "${COMPUTEDRAINTAINTKEY}" ]] && [[ "${taintval}" == "${NOSCHEDULEEFFECT}" ]] ; then
      print error "${CHECK_FAIL} node $line has fusion taint."
      taint_used=1
    fi
  done < ${TEMP_MMHEALTH_FILE}
  if [ $taint_used  -eq 0 ]; then
          print info "${CHECK_PASS} No node is under fusion maintenance."
  fi
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

#ImagePullBackOff,CrashLoopBackOff,
function verify_imagepullbackoff_pods(){
  print info "Verify unhealthy pods across cluster."
  oc get pods -A | egrep -v 'Running|Completed|NAME' 2>&1 >> /dev/null
  if [[ $? -ne 0 ]]; then
    print info "${CHECK_PASS} All pods in this cluster is healthy."
    return 0
  else
    print error "${CHECK_FAIL} Below pods in this cluster are unhealthy."
  fi

  imagepullbackoffPod=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  #while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get pods -A | grep -ivE "Running|Completed" )"
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get pods -A | egrep -v 'Running|Completed|NAME')"
  while IFS= read -r line
    do
      imagepullbackoffPod=1
      podname=$(echo $line |awk '{print $2}')
      podns=$(echo $line |awk '{print $1}')
      podstatus=$(echo $line |awk '{print $4}')
      #print error "${CHECK_FAIL} ${podname} in namespace ${podns} is failing due to ${podstatus}"
    done < ${TEMP_MMHEALTH_FILE}
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  if [ $imagepullbackoffPod -ne 0 ]; then
    oc get pods -A | egrep -v 'Running|Completed|NAME'
  fi
}

#oc get computemonitoring -n ibm-spectrum-fusion-ns monitoring-compute-1-ru5 -o json | jq .status.nodes[].nodeMonStatus.state
function verify_nodes_hw(){
  print info "Verify node hardware status"
  nodeStatus=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get computemonitoring -n ${FUSIONNS} --no-headers )"
  while IFS= read -r line
    do
      monitoringCRD=$(echo $line |awk '{print $1}')
      #check only configured nodes, not discovered one
      configuredNode=$(oc get computemonitoring -n ${FUSIONNS} $monitoringCRD -o json | jq .status.nodes[].ocpNodeName )
      if [[ "$configuredNode" != "" ]]; then
        nodeHwStatus=$(oc get computemonitoring -n ${FUSIONNS} $monitoringCRD -o json | jq .status.nodes[].nodeMonStatus.state)
        if [[ "$nodeHwStatus" == "Succeeded" ]]; then
          nodeStatus=1
          print error "${CHECK_FAIL} ${configuredNode} hardware is not healthy"
        fi
      fi
    done < ${TEMP_MMHEALTH_FILE}
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  if [ $nodeStatus -eq 0 ]; then
    print info "${CHECK_PASS} All configured nodes hardware is healthy."
  fi
}

function verify_nodes_dns () {
  print info "Verify DNS on nodes"
  dnsStatus=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get nodes --no-headers | grep -v "NotReady" )"
  while IFS= read -r line
    do
      nodeName=$(echo $line |awk '{print $1}')
      oc debug nodes/${nodeName} -- chroot /host nslookup $IBMENTITLEDREG|grep "NXDOMAIN" > /dev/null
      if [[ $? -eq 0 ]]; then
        dnsStatus=1
	print error "${CHECK_FAIL} DNS is not configured correctly on $nodeName."
      else
        print info "${CHECK_PASS} DNS is configured correctly on $nodeName."
      fi
    done < ${TEMP_MMHEALTH_FILE}
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

function verify_link(){
  print info "Verify Link"
  linkStatus=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get link -n ${FUSIONNS} --no-headers )"
  while IFS= read -r line
    do
      linkName=$(echo $line |awk '{print $1}')
      linkuuid=$(oc get link -n ${FUSIONNS} $linkName -o json | jq .spec.torLinkSpec[].uuid)
      linkCreatedStatus=$(oc get link -n ${FUSIONNS} $linkName -o json | jq .status.torUplinkStatus.$linkuuid.linkCreated)
      linkState=$(oc get link -n ${FUSIONNS} $linkName -o json | jq .status.torUplinkStatus.$linkuuid.linkState)
      if [[ "$linkCreatedStatus" != "true" ]] && [[ "$linkState" != "true" ]] ; then
        linkStatus=1
	print error "${CHECK_FAIL} Link $linkName status is $linkState."
      else
    	print info "${CHECK_PASS} Link $linkName is healthy."
      fi
    done < ${TEMP_MMHEALTH_FILE}
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

function verify_switches(){
  print info "Verify switch"
  switchStatus=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get switches -n ${FUSIONNS} --no-headers )"
  while IFS= read -r line
    do
      switchName=$(echo $line |awk '{print $1}')
      switchLogin=$(oc get switches -n ${FUSIONNS} $switchName -o json | jq .status.status)
      switchState=$(oc get switches -n ${FUSIONNS} $switchName -o json | jq .status.powerStatus.state)
      if [[ $switchLogin == "login successful" ]] && [[ $switchState == "OK" ]] ; then
        switchStatus=1
	print error "${CHECK_FAIL} Switch $switchName status is $switchState ."
      else
        print info "${CHECK_PASS} Switch $switchName is healthy."
      fi
    done < ${TEMP_MMHEALTH_FILE}
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

function verify_vlan(){
  print info "Verify vlan"
  vlanStatus=0
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
  while read -r proc; do echo $proc >> ${TEMP_MMHEALTH_FILE}; done <<< "$(oc get vlan -n ${FUSIONNS} --no-headers )"
  while IFS= read -r line
    do
      vlanName=$(echo $line |awk '{print $1}')
      vlanids=$(oc get vlan -n ${FUSIONNS} ${vlanName} -o json | jq .spec.torVlanSpec[].vlanId)
      for vlanId in $vlanids
      do
        vlanCreated=$(oc get vlan -n ibm-spectrum-fusion-ns rack-vlans -o json | jq '.status.torVlanStatus."1".vlanCreated')
        vlanIdStatus=$(oc get vlan -n ibm-spectrum-fusion-ns rack-vlans -o json | jq '.status.torVlanStatus."1".vlanStatus')
        if [[ $vlanCreated ]] && [[ $vlanIdStatus = "Success" ]] ; then
          vlanStatus=1
          print error "${CHECK_FAIL} Vlan $vlanId status is $vlanIdStatus ."
	else
 	  print info "${CHECK_PASS} vlan $vlanId is heathy."
        fi
      done
    done < ${TEMP_MMHEALTH_FILE}
  rm -f ${TEMP_MMHEALTH_FILE} >> /dev/null
}

function verify_network_checks(){
verify_nodes_dns
print_subsection
verify_link
print_subsection
verify_switches
print_subsection
verify_vlan
}

rm -f ${REPORT} > /dev/null
print_header
print_section "API access"
verify_api_access
print_section "Registry access"
areRegistriesAccessible
print_section "Registry authentication and authorisation"
isAuthCorrect
print_section "Cluster operators"
verify_clusteroperators_status
print_section "Nodes"
verify_nodes_status
print_section "Machine configuration pools"
verify_mcp
print_section "Catalog sources"
verify_catsrc
print_section "Fusion software"
verify_fusion_health
print_section "Backup & Restore"
verify_br_health
print_section "Legacy SPP"
verify_spp_health
print_section "Data Classification"
verify_dcs_health
print_section "Scale cluster"
verify_scale_health
print_section "VMs migration"
verify_livemigratable_vms
print_section "Pods with imagepullbackoff across cluster"
verify_imagepullbackoff_pods
print_section "Nodes hardware status"
verify_nodes_hw
print_section "Fusion nodes maintenance"
verify_node_taints
print_section "Network checks"
verify_network_checks
print_footer
