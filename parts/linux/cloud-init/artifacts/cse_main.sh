#!/bin/bash
ERR_FILE_WATCH_TIMEOUT=6 {{/* Timeout waiting for a file */}}
set -x
if [ -f /opt/azure/containers/provision.complete ]; then
      echo "Already ran to success exiting..."
      exit 0
fi

UBUNTU_RELEASE=$(lsb_release -r -s)
if [[ ${UBUNTU_RELEASE} == "16.04" ]]; then
    sudo apt-get -y autoremove chrony
    echo $?
    sudo systemctl restart systemd-timesyncd
fi

echo $(date),$(hostname), startcustomscript>>/opt/m

for i in $(seq 1 3600); do
    if [ -s {{GetCSEHelpersScriptFilepath}} ]; then
        grep -Fq '#HELPERSEOF' {{GetCSEHelpersScriptFilepath}} && break
    fi
    if [ $i -eq 3600 ]; then
        exit $ERR_FILE_WATCH_TIMEOUT
    else
        sleep 1
    fi
done
sed -i "/#HELPERSEOF/d" {{GetCSEHelpersScriptFilepath}}
source {{GetCSEHelpersScriptFilepath}}

wait_for_file 3600 1 {{GetCSEInstallScriptFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
source {{GetCSEInstallScriptFilepath}}

wait_for_file 3600 1 {{GetCSEConfigScriptFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
source {{GetCSEConfigScriptFilepath}}

set +x
ETCD_PEER_CERT=$(echo ${ETCD_PEER_CERTIFICATES} | cut -d'[' -f 2 | cut -d']' -f 1 | cut -d',' -f $((${NODE_INDEX}+1)))
ETCD_PEER_KEY=$(echo ${ETCD_PEER_PRIVATE_KEYS} | cut -d'[' -f 2 | cut -d']' -f 1 | cut -d',' -f $((${NODE_INDEX}+1)))
set -x

if [[ $OS == $COREOS_OS_NAME ]]; then
    echo "Changing default kubectl bin location"
    KUBECTL=/opt/kubectl
fi

if [ -f /var/run/reboot-required ]; then
    REBOOTREQUIRED=true
else
    REBOOTREQUIRED=false
fi

configureAdminUser

{{- if not NeedsContainerd}}
cleanUpContainerd
{{end}}

if [[ "${GPU_NODE}" != "true" ]]; then
    cleanUpGPUDrivers
fi

VHD_LOGS_FILEPATH=/opt/azure/vhd-install.complete
if [ -f $VHD_LOGS_FILEPATH ]; then
    echo "detected golden image pre-install"
    cleanUpContainerImages
    FULL_INSTALL_REQUIRED=false
else
    if [[ "${IS_VHD}" = true ]]; then
        echo "Using VHD distro but file $VHD_LOGS_FILEPATH not found"
        exit $ERR_VHD_FILE_NOT_FOUND
    fi
    FULL_INSTALL_REQUIRED=true
fi

if [[ $OS == $UBUNTU_OS_NAME ]] && [ "$FULL_INSTALL_REQUIRED" = "true" ]; then
    installDeps
else
    echo "Golden image; skipping dependencies installation"
fi

if [[ $OS == $UBUNTU_OS_NAME ]]; then
    ensureAuditD
fi

installContainerRuntime
{{- if NeedsContainerd}}
installCrictl
# If crictl gets installed then use it as the cri cli instead of ctr
CLI_TOOL="crictl"
{{- if TeleportEnabled}}
installTeleportdPlugin
{{end}}
{{end}}

installNetworkPlugin

{{- if IsNSeriesSKU}}
echo $(date),$(hostname), "Start configuring GPU drivers"
if [[ "${GPU_NODE}" = true ]]; then
    if $FULL_INSTALL_REQUIRED; then
        installGPUDrivers
    fi
    ensureGPUDrivers
    if [[ "${ENABLE_GPU_DEVICE_PLUGIN_IF_NEEDED}" = true ]]; then
        systemctlEnableAndStart nvidia-device-plugin || exit $ERR_GPU_DEVICE_PLUGIN_START_FAIL
    else
        systemctlDisableAndStop nvidia-device-plugin
    fi
fi
echo $(date),$(hostname), "End configuring GPU drivers"
{{end}}

{{- if and IsDockerContainerRuntime HasPrivateAzureRegistryServer}}
docker login -u $SERVICE_PRINCIPAL_CLIENT_ID -p $SERVICE_PRINCIPAL_CLIENT_SECRET {{GetPrivateAzureRegistryServer}}
{{end}}

installKubeletKubectlAndKubeProxy

if [[ $OS != $COREOS_OS_NAME ]]; then
    ensureRPC
fi

createKubeManifestDir

{{- if HasDCSeriesSKU}}
if [[ ${SGX_NODE} == true && ! -e "/dev/sgx" ]]; then
    installSGXDrivers
fi
{{end}}

{{- if HasCustomSearchDomain}}
wait_for_file 3600 1 {{GetCustomSearchDomainsCSEScriptFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
{{GetCustomSearchDomainsCSEScriptFilepath}} > /opt/azure/containers/setup-custom-search-domain.log 2>&1 || exit $ERR_CUSTOM_SEARCH_DOMAINS_FAIL
{{end}}

configureK8s

configureCNI

{{/* configure and enable dhcpv6 for dual stack feature */}}
{{- if IsIPv6DualStackFeatureEnabled}}
ensureDHCPv6
{{- end}}

{{- if NeedsContainerd}}
ensureContainerd {{/* containerd should not be configured until cni has been configured first */}}
{{- else}}
ensureDocker
{{- end}}

ensureMonitorService

{{- if EnableHostsConfigAgent}}
configPrivateClusterHosts
{{- end}}

{{- if ShouldConfigTransparentHugePage}}
configureTransparentHugePage
{{- end}}

{{- if ShouldConfigSwapFile}}
configureSwapFile
{{- end}}

ensureSysctl
ensureKubelet
ensureLabels
ensureJournal

if $FULL_INSTALL_REQUIRED; then
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        {{/* mitigation for bug https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1676635 */}}
        echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind
        sed -i "13i\echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind\n" /etc/rc.local
    fi
fi

{{- /* re-enable unattended upgrades */}}
rm -f /etc/apt/apt.conf.d/99periodic

if [[ $OS == $UBUNTU_OS_NAME ]]; then
    apt_get_purge 20 30 120 apache2-utils &
fi

VALIDATION_ERR=0

API_SERVER_DNS_RETRIES=20
if [[ $API_SERVER_NAME == *.privatelink.* ]]; then
  API_SERVER_DNS_RETRIES=200
fi
{{- if not EnableHostsConfigAgent}}
RES=$(retrycmd_if_failure ${API_SERVER_DNS_RETRIES} 1 3 nslookup ${API_SERVER_NAME})
STS=$?
{{- else}}
STS=0
{{- end}}
if [[ $STS != 0 ]]; then
    if [[ $RES == *"168.63.129.16"*  ]]; then
        VALIDATION_ERR=$ERR_K8S_API_SERVER_AZURE_DNS_LOOKUP_FAIL
    else
        VALIDATION_ERR=$ERR_K8S_API_SERVER_DNS_LOOKUP_FAIL
    fi
else
    API_SERVER_CONN_RETRIES=50
    if [[ $API_SERVER_NAME == *.privatelink.* ]]; then
        API_SERVER_CONN_RETRIES=100
    fi
    retrycmd_if_failure ${API_SERVER_CONN_RETRIES} 1 3 nc -vz ${API_SERVER_NAME} 443 || VALIDATION_ERR=$ERR_K8S_API_SERVER_CONN_FAIL
fi

if $REBOOTREQUIRED; then
    echo 'reboot required, rebooting node in 1 minute'
    /bin/bash -c "shutdown -r 1 &"
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        aptmarkWALinuxAgent unhold &
    fi
else
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        /usr/lib/apt/apt.systemd.daily &
        aptmarkWALinuxAgent unhold &
    fi
fi

echo "Custom script finished. API server connection check code:" $VALIDATION_ERR
echo $(date),$(hostname), endcustomscript>>/opt/m
mkdir -p /opt/azure/containers && touch /opt/azure/containers/provision.complete
ps auxfww > /opt/azure/provision-ps.log &

exit $VALIDATION_ERR

#EOF
