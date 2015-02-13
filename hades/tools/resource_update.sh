container_id=$1
resource=$2

if [ "$resource" = "net" ]; then
    in_rate=$3
    out_rate=$4
    echo "$in_rate"
    echo "$out_rate"
                        
    tc class del dev $container_id classid 1:1
    tc qdisc del dev $container_id ingress
    tc class add dev $container_id parent 1: classid 1:1 htb rate "${in_rate}mbps" 
    tc qdisc add dev $container_id ingress handle ffff:
    tc filter add dev $container_id parent ffff: protocol ip prio 1 u32 match ip src 0.0.0.0/0 police rate "${out_rate}mbps" burst 5mb  mtu 64kb drop flowid :1

fi

