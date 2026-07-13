# configure gNB parameters
#!/bin/bash

source common/ip_utils.sh
source common/confirm_answer.sh
source common/docker_utils.sh

#set -x

VCU_CONTAINER=$1
EXEC_K8S=0
VERBOSE=0
CLI_CMD="/usr/sbin/rgcli"
pod="cu-rt-demo-0"

operator_id=0
gnb_id=
amf_ip=
amf_plmn=46007
ngap_ip=
amf_subnet=
amf_gw=
ngu_gw=
cell_name=
gnb_name=
freq_band=41
phy_cell_index=
cell_dl_arfcn=519138
cell_ssb_arfcn=510030
cell_tac=81
cell_txrx_mode="4T4R"
slice_sst=1
slice_sd=123
cell_ant_mode=0x0000
cell_inactive_timer=0 #off
gnb_frame_offset=0
host_debug_nic="eno1"
host_debug_ip=

function print_usage() {
    echo "Usage: $0 <vCU container name>"
    echo
    echo "Options:"
    echo -e "\t-k: configure parameters for Kubernetes vCU pod, otherwise for vCU docker container.\n"
    echo -e "\t-v: Print configuration command before executing.\n"
    echo
    echo "Examples: configure parameters for vCU docker container"
    echo "$0 -v vcu_container"
    echo
    echo "Examples: configure parameters for vCU k8s pod"
    echo "$0 -v -k vcu_pod"
    echo
    exit 0
}

check_string_not_empty() {
    local str="$1"
    local err_str="$2"

    if [ -z "$str" ]; then
        if [ -n "$err_str" ]; then
            echo $err_str
        fi

        return 1
    else
        return 0
    fi
}

get_user_input() {
    local prompt="$1"
    local user_input=""

    while true; do
        read -p "$prompt" user_input

        if [[ -z "$user_input" ]]; then
            echo "Error: NULL input. Please input a value." >&2
        else
            break
        fi
    done

    echo "$user_input"
}

check_integer_range() {
    local num="$1"
    local min="$2"
    local max="$3"

    if [[ -z "$num" || -z "$min" || -z "$max" ]]; then
        echo "Error：NULL parameters！num=$num, min=$min, max=$max." >&2
        return 1
    fi

    if ! [[ "$num" =~ ^-?[0-9]+$ ]] || ! [[ "$min" =~ ^-?[0-9]+$ ]] || ! [[ "$max" =~ ^-?[0-9]+$ ]]; then
        echo "Error：Invalid integer！" >&2
        return 1
    fi

    if (( min > max )); then
        echo "Error：min=$min shall be less than max=$max！" >&2
        return 1
    fi

    if (( num >= min && num <= max )); then
        return 0
    else
        echo "Invalid value $num! Input value range shall be [$min, $max]." >&2
        return 1
    fi
}

read_integer_in_range() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local default_val="$4"
    local user_input=""

    if ! [[ "$min" =~ ^-?[0-9]+$ ]] || ! [[ "$max" =~ ^-?[0-9]+$ ]]; then
        echo "Error range (min and max) parameters！min=$min, max=$max." >&2
        return 1
    fi

    if (( min > max )); then
        echo "Error：min=$min, larger than max=$max！" >&2
        return 1
    fi

    while true; do
        read -p "${prompt}" user_input

        if [[ -z "$user_input" ]]; then
            if [[ -z "${default_val}" ]]; then
                echo "Error：NULL input." >&2
                continue
            else
                user_input=${default_val}
                echo "Using default value: ${user_input}" >&2
            fi
        fi

        if ! [[ "$user_input" =~ ^-?[0-9]+$ ]]; then
            echo "Errior：input value shall be an integer." >&2
            continue
        fi

        if (( user_input >= min && user_input <= max )); then
            echo "$user_input"
            return 0
        else
            echo "Invalid input value $num! Input value range shall be [$min, $max]." >&2
        fi
    done
}

read_ipv4_addr() {
    local prompt="$1"
    local default_ip="$2"
    local ip_addr=""

    while true; do
        read -p "$prompt" ip_addr

        if [[ -z "$ip_addr" ]]; then
            if [[ -z "$default_ip" ]]; then
                echo "Error：NULL IP addr！" >&2
                continue
            else
                ip_addr="$default_ip"
            fi
        fi

        if [[ "$ip_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            local IFS='.'
            local -a octets=($ip_addr)
            local is_valid=1

            for octet in "${octets[@]}"; do
                if (( octet < 0 || octet > 255 )); then
                    is_valid=0
                    break
                fi
            done

            if (( is_valid )); then
                echo "$ip_addr"
                return 0
            fi
        fi

        echo "Error：'$ip_addr' is an invalid IPv4 address." >&2
    done
}

get_ipv4_subnet() {
    local ip_addr="$1"
    local mask_bits="$2"
    local subnet=""

    if ! [[ "$ip_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Errir：Invalid IPv4 address" >&2
        return 1
    fi

    if ! [[ "$mask_bits" =~ ^[0-9]+$ ]] || (( mask_bits < 0 || mask_bits > 32 )); then
        echo "Error：netmask shall be 0-32 bits" >&2
        return 1
    fi

    local mask=$(( 0xffffffff << (32 - mask_bits) ))

    IFS='.' read -r i1 i2 i3 i4 <<< "$ip_addr"
    local ip=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))

    local net=$(( ip & mask ))

    subnet=$(( (net >> 24) & 0xff )).$(( (net >> 16) & 0xff )).$(( (net >> 8) & 0xff )).$(( net & 0xff ))

    echo "$subnet"
    return 0
}

exec_rgcli()
{
    local rgcli_cmd="$1"
    local error_redirect=$2
    local exec_cmdline=

    check_string_not_empty $rgcli_cmd "NULL rgcli commnad specified."
    if [ $? -ne 0 ]; then
        return 1
    fi

    if [ $EXEC_K8S -eq 0 ]; then
        exec_cmdline="docker exec -it $VCU_CONTAINER ${CLI_CMD} -c \"${rgcli_cmd}\" ${error_redirect}"
    else
        exec_cmdline="kubectl exec -it ${pod} -- ${CLI_CMD} -c \"${rgcli_cmd}\" ${error_redirect}"
    fi

    if [ $VERBOSE -eq 1 ]; then
        echo $exec_cmdline
    fi

    eval $exec_cmdline

    return $?
}

set_gnb_password()
{
  read -p "Would you like to set the gNB password? (yes/no): " answer
  input_answer $answer
  if [ $? -ne 0 ]; then
    return 0
  else
    echo "Set opr password"
    exec_rgcli "set user-password :name=opr"

    echo "Set root password"
    exec_rgcli "set user-password :name=root"
  fi
}

config_operators()
{
    local minval="1"
    local maxval="10000"
    local result
    local output
    local opr_plmn=46007

    gnb_id=$(read_integer_in_range "Please input gNB Id (${minval} - ${maxval})：" "${minval}" "${maxval}")
    echo "gNB Id=$gnb_id"

    gnb_name="gnb-${gnb_id}"
    cell_name="cell1-${gnb_id}"

    result=$(exec_rgcli "list gnbcu-operator :operator-id=$operator_id" 2>&1)

    if [[ $? -eq 0 ]] && [[ ! "$result" =~ "does not exist" ]]; then
        echo "CU Operator $operator_id exists. You need to delele it before addting a new operator $operator_id."
        read -p "Do you delete the CU operator $operator_id? (yes/no): " answer
        input_answer $answer
        if [ $? -eq 0 ]; then
            exec_rgcli "del gnbcu-operator: operator-id=$operator_id"
        fi
    fi

    amf_plmn=$(read_integer_in_range "Please input PLMN, (${minval} - ${maxval}) default=$opr_plmn：" "1" "46099" "$opr_plmn")

    exec_rgcli "add gnbcu-operator :operator-id=0 operator-name=\"CMCC\" operator-type=primary-operator gnbid=${gnb_id} gnbid-len=24 plmnid=\"${amf_plmn}\""

    result=$(exec_rgcli "list gnbdu-operator :operator-id=$operator_id slot=1" 2>&1)

    if [[ $? -eq 0 ]] && [[ ! "$result" =~ "does not exist" ]]; then
        echo "DU Operator $operator_id (slot=1) exists. You need to delele it before addting a new operator $operator_id."
        read -p "Do you delete the DU operator $operator_id? (yes/no): " answer
        input_answer $answer
        if [ $? -eq 0 ]; then
            exec_rgcli "del gnbdu-operator: operator-id=$operator_id slot=1"
        fi
    fi
    exec_rgcli "add gnbdu-operator : operator-id=0 gnbid=${gnb_id} gnbid-len=24 operator-name=\"CMCC\" operator-type=PRIMARY_OPERATOR plmnlist=\"${amf_plmn}\" gnbname=\"${gnb_name}\" slot=1"

    output=$(exec_rgcli "list gnbcu-operator :operator-id=$operator_id" 2>&1)
    local cu_gnbid=$(echo "$output" | awk -F': +' '/^[[:space:]]*gnbid[[:space:]]*:/ {
    val = $2;
    match(val, /[^[:space:]].*[^[:space:]]/);
    if (RSTART) print substr(val, RSTART, RLENGTH);
    else print "";
}')

    local cu_gnbid_len=$(echo "$output" | awk -F': +' '/^[[:space:]]*gnbid-len[[:space:]]*:/ {
    val = $2;
    match(val, /[^[:space:]].*[^[:space:]]/);
    if (RSTART) print substr(val, RSTART, RLENGTH);
    else print "";
}')

    if [ -z "$cu_gnbid" ] || [ -z "$cu_gnbid_len" ]; then
        echo "Error: Could not extract CU gnbid or gnbid len: cu_gnbid=${cu_gnbid}, cu_gnbid_len=${cu_gnbid_len}"
        exit 1
    fi

    output=$(exec_rgcli "list gnbdu-operator :operator-id=$operator_id slot=1" 2>&1)
    local du_gnbid=$(echo "$output" | awk -F': +' '/^[[:space:]]*Gnbid[[:space:]]*:/ {
    val = $2;
    match(val, /[^[:space:]].*[^[:space:]]/);
    if (RSTART) print substr(val, RSTART, RLENGTH);
    else print "";
}')

    local du_gnbid_len=$(echo "$output" | awk -F': +' '/^[[:space:]]*Gnbid len[[:space:]]*:/ {
    val = $2;
    match(val, /[^[:space:]].*[^[:space:]]/);
    if (RSTART) print substr(val, RSTART, RLENGTH);
    else print "";
}')

    if [ -z "$du_gnbid" ] || [ -z "$du_gnbid_len" ]; then
        echo "Error: Could not extract DU Gnbid or Gnbid len: du_gnbid=${du_gnbid}, du_gnbid_len=${du_gnbid_len}"
        exit 1
    fi

    if [[ "$cu_gnbid" != "$du_gnbid" ]] || [[ "$du_gnbid_len" != "$cu_gnbid_len" ]]; then
        echo "ERROR: CU GnbId is not equal to DU GnbId. cu_gnbid=${cu_gnbid}, cu_gnbid_len=${cu_gnbid_len}, du_gnbid=${du_gnbid}, du_gnbid_len=${du_gnbid_len}"
        exit 1
    fi
}

config_amf_pool()
{
    amf_ip=$(read_ipv4_addr "Please input AMF IP address: ")
    ngap_ip=$(read_ipv4_addr "Please input NG interface address of gNB: ")
    amf_subnet=$(get_ipv4_subnet "${amf_ip}" 24)
    amf_gw=$(echo "$amf_ip" | awk -F. '{print $1"."$2"."$3".1"}')

    amf_gw=$(read_ipv4_addr "Please input the gateway IP of NG/AMF subnet(default $amf_gw): " "${amf_gw}")
    ngu_gw=$(read_ipv4_addr "Please input the default gateway IP of NG-U subnet: ")

    echo "AMF IP=${amf_ip}, NGAP IP=${ngap_ip}, AMF subnet=${amf_subnet}， NG/AMF default GW=${amf_gw}"

    exec_rgcli "add amfpool :amfid=0 operator-id=0 amfip1=\"${amf_ip}\""
    exec_rgcli "add ipv4-address :interface=NG ipv4=${ngap_ip} mask=255.255.255.0 nr-port-type=Ng"
    exec_rgcli "add ipv4-route :interface=NG dst-ipv4=0.0.0.0 mask=0 next-hop=${ngu_gw}"
    exec_rgcli "show amfpool"
}

config_cu_du_cell()
{
    local minval="1"
    local maxval="79"
    local n_band=$(read_integer_in_range "Please input frequency band (${minval} - ${maxval}, e.g. 41, 79)：" "${minval}" "${maxval}")
    freq_band="n${n_band}"

    minval="1"
    maxval="1000000"
    cell_dl_arfcn=$(read_integer_in_range "Please input DL NRARFCN of the cell (${minval} - ${maxval}), default=$cell_dl_arfcn：" "${minval}" "${maxval}" "$cell_dl_arfcn")

    minval="1"
    maxval="1000000"
    cell_ssb_arfcn=$(read_integer_in_range "Please input SSB ARFCN of the cell (${minval} - ${maxval}), default=$cell_ssb_arfcn：" "${minval}" "${maxval}" "$cell_ssb_arfcn")

    minval="1"
    maxval="1007"
    phy_cell_index=$(read_integer_in_range "Please input PCI of the cell (${minval} - ${maxval})：" "${minval}" "${maxval}")

    minval="1"
    maxval="1000"
    cell_tac=$(read_integer_in_range "Please input TAC of the cell (${minval} - ${maxval}), default=$cell_tac：" "${minval}" "${maxval}" "$cell_tac")

    minval="1"
    maxval="2"
    local cell_txrx_mode_num=$(read_integer_in_range "Please input TxRx mode of the cell (1: 2T2R, 2:4T4R), default=2：" "${minval}" "${maxval}" "2")

    if [ $cell_txrx_mode_num -eq 1 ]; then
        cell_txrx_mode="2T2R"
    else
        cell_txrx_mode="4T4R"
    fi

    exec_rgcli "add nrcell :nrcellid=0 cellid=0 duplexsete=cell-tdd frequencyband=$freq_band cellname=\"${cell_name}\""

    exec_rgcli "add nrducell : nrducell-id=0 cellid=0 cyclic-prefix-length=NCP dl-bandwidth=CELL_BW_100M ul-bandwidth=CELL_BW_100M dl-narfcn=$cell_dl_arfcn ul-narfcn=$cell_dl_arfcn freq-band=N$n_band logical-rootseqindex=137 operator-id=0 pci=$phy_cell_index ranac=0 tac=$cell_tac ssb-descmethod=SSB_DESC_TYPE_NARFCN slot-assignment=8_2_DDDDDDDSUU slot-structure=SS2 ssb-period=MS20 txrx-mode=${cell_txrx_mode} duplex-mode=CELL_TDD nrducell-name=\"${cell_name}\" ssb-freq-pos=$cell_ssb_arfcn slot=1"

    exec_rgcli "list nrcell"

    exec_rgcli "show nrducell :slot=1"
}

config_slice()
{
    read -p "Would you like to set the gNB slice? (yes/no): " answer
    input_answer $answer
    if [ $? -ne 0 ]; then
      return 0
    fi

    local minval="1"
    local maxval="255"
    slice_sst=$(read_integer_in_range "Please input SST of network slice (${minval} - ${maxval}), default(eMBB)=$slice_sst：" "${minval}" "${maxval}" "$slice_sst")

    minval="1"
    maxval="100000"
    slice_sd=$(read_integer_in_range "Please input SD of network slice (${minval} - ${maxval})：" "${minval}" "${maxval}")

    exec_rgcli "add nrducell-nsgrp : slot=1 nrducell-id=0 nsgrp-id=1"
    exec_rgcli "add nrducell-nsgrpns: slot=1 nrducell-id=0 nsgrp-id=1 ns-sst=$slice_sst ns-sd=$slice_sd operator-id=0"
}

config_rru()
{
    read -p "Would you switch the gNB antennas to external ANT mode? (yes/no): " answer
    input_answer $answer
    if [ $? -ne 0 ]; then
          cell_ant_mode=0x0000
          echo "Cell is set to internal ANT mode: $cell_ant_mode"
    else
          cell_ant_mode=0x0f03
          echo "Cell is set to external ANT mode: $cell_ant_mode"
    fi

    exec_rgcli "list rru :slot=1"
    exec_rgcli "add rru-group : group-id=0 slot=1"
    exec_rgcli "add rru-groupeqm : group-id=0 rcn=0 slot=1"
    exec_rgcli "add nrducell-coverage : max-transmit-power=24 group-id=0 nrducell-coverage-id=0 nrducell-id=0 slot=1"
    exec_rgcli "set rru:rcn=0 ant-mode=$cell_ant_mode slot=1"
}

config_cipher()
{
    read -p "Would you like to configure gNB to support Ciphering and Integrity Protection? (yes/no): " answer
    input_answer $answer
    if [ $? -ne 0 ]; then
      return 0
    fi

    exec_rgcli "set cupdcp-cipher-capb:primary-cipher-algo=nea0  second-cipher-algo=nea0  third-cipher-algo=nea0  fourth-cipher-algo=nea0"
    exec_rgcli "set cupdcp-integrity-capb:primary-integrity-algo=nia1  second-integrity-algo=nia1  third-integrity-algo=nia1"
    exec_rgcli "set cupdcp-cipher-capb:primary-cipher-algo=nea1  second-cipher-algo=nea1  third-cipher-algo=nea1  fourth-cipher-algo=nea1"
    exec_rgcli "set cupdcp-userplane-cipheren:switch=enable"
    exec_rgcli "set cupdcp-userplane-integrityen:switch=enable"
    exec_rgcli "set cupdcp-paramgroup:cupdcp-paramgroup-id=0  userplane-cipheren=enable  userplane-integrityen=enable"
    exec_rgcli "set cupdcp-paramgroup:cupdcp-paramgroup-id=2  userplane-cipheren=enable  userplane-integrityen=enable"
    exec_rgcli "set cupdcp-paramgroup:cupdcp-paramgroup-id=8  userplane-cipheren=enable  userplane-integrityen=enable"
}

config_inactive_timer()
{
    local minval="1"
    local maxval="3600"
    read -p "Would you like to turn off UE inactive timer? (yes/no): " answer
    input_answer $answer
    if [ $? -eq 0 ]; then
        exec_rgcli "set nrcell-inactivetimer:cellid=0 timervalue=0"
    else
        cell_inactive_timer=$(read_integer_in_range "Please input UE inactive timer (${minval} - ${maxval}), default=1000：" "${minval}" "${maxval}" "1000")
        exec_rgcli "set nrcell-inactivetimer:cellid=0 timervalue=${cell_inactive_timer}"
    fi
}

config_csirs_trs()
{
    exec_rgcli "set nrducell-csirs :nrducell-id=0 slot=1 res-adapt-switch=disable"

    read -p "Would you like to turn off TRS (suggestion=no)? (yes/no): " answer
    input_answer $answer
    if [ $? -eq 0 ]; then
          exec_rgcli "set nrducell-csirs :nrducell-id=0 trs-period=SLOT0 slot=1"
    else
          exec_rgcli "set nrducell-csirs :nrducell-id=0 trs-period=SLOT40 slot=1"
    fi
}

activate_cell()
{
    read -p "Would you like to activate the cell ($cell_name)? (yes/no): " answer
    input_answer $answer
    if [ $? -ne 0 ]; then
          echo "You need to enter vCU container and activate the $cell_name via rgcli: set nrcellactive:nrcellid=0 cellstatus=enable"
      return 0
    fi

    exec_rgcli "set nrcellactive:nrcellid=0 cellstatus=enable"
    exec_rgcli "list nrcell: cellid=0"
}

config_eweb_connection()
{
    systemctl stop firewalld
    systemctl disable firewalld
}

config_frame_offset()
{
    echo "The current gNB frame-offset is:"
    exec_rgcli "list gnb-frame-offset:slot=1"

    read -p "Do you want to change the gNB frame-offset? (yes/no): " answer
    input_answer $answer
    if [ $? -ne 0 ]; then
      return 0
    fi

    local minval="0"
    local maxval="3000000"
    gnb_frame_offset=$(read_integer_in_range "Please input frame-offset (0: 0ms, 2302343: 2.3ms (default), 3000000: 3ms)：" "${minval}" "${maxval}" "2302343")

    exec_rgcli "set gnb-frame-offset : slot=1 value=${gnb_frame_offset}"
}

check_cell_ul_noise()
{
    exec_rgcli "show gnb-cell-noise : nrducellid=0 slot=1"
}

if [ $# -eq 0 ] || [ $1 == -h ]; then print_usage; fi

OPTIND=1

while getopts :hkvi: opt

do
    case $opt in
    k)
        EXEC_K8S=1
        ;;
    v)
        VERBOSE=1
        ;;
    h)
        print_usage
        ;;
    :)
        echo "ERROR: -$OPTARG expects an corresponding argument" >&2
        print_usage
        ;;
    \?)
        echo "ERROR: unkown option -$OPTARG" >&2
        print_usage
        ;;
    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift

LEFT_OVERS=$@
VCU_CONTAINER=${LEFT_OVERS}

check_string_not_empty "$VCU_CONTAINER" "Error: No vCU container name specified."
if [ $? -ne 0 ]; then
    print_usage
fi


if [ $EXEC_K8S -eq 0 ]; then
    check_container_running $VCU_CONTAINER
    RETVAL=$?

    if [ $RETVAL -eq 0 ]; then
      echo "Container $VCU_CONTAINER found."
    else
      echo "Please double check if vCU container is running."
      exit 1
    fi

    read -p "Configure gNB parameters for docker container: $VCU_CONTAINER, continue? (yes/no): " answer
else
    read -p "Configure gNB parameters for k8s pod: $VCU_CONTAINER, continue? (yes/no): " answer
fi


input_answer $answer
if [ $? -ne 0 ]; then
    exit 0
fi
  
set_gnb_password

config_operators

config_amf_pool

while true; do

    config_cu_du_cell 

    read -p "Would you like to add one more cell? (yes/no): " answer
    input_answer $answer
    if [ $? -ne 0 ]; then
        break
    else
        echo "Add cell..."
    fi
done

config_slice

config_rru

config_cipher

config_inactive_timer

config_csirs_trs

config_frame_offset

config_eweb_connection

activate_cell

sleep 3

check_cell_ul_noise
