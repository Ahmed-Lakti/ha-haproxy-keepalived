global_defs {
    router_id LB_${SRC_IP}
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/local/bin/check_haproxy.sh"
    interval 2      # test toutes les 2 s
    fall 2          # 2 échecs => KO
    rise 2          # 2 succès => OK
    weight -20      # priorité -20 si HAProxy est KO (110 -> 90 < 100 du backup)
}

vrrp_instance VI_1 {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1

    unicast_src_ip ${SRC_IP}
    unicast_peer {
        ${PEER_IP}
    }

    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }

    virtual_ipaddress {
        ${VIP}/24 dev ${IFACE}
    }

    track_script {
        chk_haproxy
    }
}
