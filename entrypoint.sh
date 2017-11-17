#!/bin/sh

set -e

DOMAIN=${DOMAIN:-domain.tld}
DOMAIN_SUFFIX="dc=`echo $DOMAIN | sed -e 's/\./,dc=/g'`"

LDAP_BASE_FILTER=${LDAP_BASE_FILTER:-'(&(objectClass=radiusAccount)(uid=%{User-Name}))'}

cat << EOF > /etc/raddb/users
DEFAULT	Framed-Protocol == PPP
	Framed-Protocol = PPP,
	Framed-Compression = Van-Jacobson-TCP-IP
DEFAULT	Hint == "CSLIP"
	Framed-Protocol = SLIP,
	Framed-Compression = Van-Jacobson-TCP-IP
DEFAULT	Hint == "SLIP"
	Framed-Protocol = SLIP
DEFAULT Auth-Type = LDAP
	Fall-Through = 1
EOF

cat << EOF > /etc/raddb/clients.conf
client * {
	secret = secret
}
EOF

cat << EOF > /etc/raddb/mods-enabled/ldap
ldap {
	server = "$LDAP_URL"
	identity = "${LDAP_BIND_DN:-cn=Manager,$DOMAIN_SUFFIX}"
	password = "$LDAP_BIND_PW"
	base_dn = "$DOMAIN_SUFFIX"
	update {
		control:Password-With-Header	+= 'userPassword'
		control:			+= 'radiusControlAttribute'
		request:			+= 'radiusRequestAttribute'
		reply:				+= 'radiusReplyAttribute'
	}
	user {
		base_dn = "\${..base_dn}"
		filter = "$LDAP_BASE_FILTER"
		password_attribute = userPassword
	}
	group {
		base_dn = "\${..base_dn}"
		filter = '(objectClass=posixGroup)'
		membership_attribute = 'memberOf'
	}
	profile {
	}
	client {
		base_dn = "\${..base_dn}"
		filter = '(objectClass=radiusClient)'
		template {
		}
		attribute {
			ipaddr				= 'radiusClientIdentifier'
			secret				= 'radiusClientSecret'
		}
	}
	accounting {
		reference = "%{tolower:type.%{Acct-Status-Type}}"
		type {
			start {
				update {
					description := "Online at %S"
				}
			}
			interim-update {
				update {
					description := "Last seen at %S"
				}
			}
			stop {
				update {
					description := "Offline at %S"
				}
			}
		}
	}
	post-auth {
		update {
			description := "Authenticated at %S"
		}
	}
	options {
		chase_referrals = yes
		rebind = yes
		res_timeout = 10
		srv_timelimit = 3
		net_timeout = 1
		idle = 60
		probes = 3
		interval = 3
		ldap_debug = 0x0028
	}
	tls {
	}
	pool {
		start = \${thread[pool].start_servers}
		min = \${thread[pool].min_spare_servers}
		max = \${thread[pool].max_servers}
		spare = \${thread[pool].max_spare_servers}
		uses = 0
		retry_delay = 30
		lifetime = 0
		idle_timeout = 60
	}
}
EOF

cat << EOF > /etc/raddb/sites-enabled/default
server default {
	listen {
		type = auth
		ipaddr = *
		port = 0
		limit {
			  max_connections = 16
			  lifetime = 0
			  idle_timeout = 30
		}
	}
	authorize {
		ldap
		filter_username
		preprocess
		chap
		mschap
		digest
		suffix
		files
		expiration
		logintime
		pap
	}
	authenticate {
		Auth-Type LDAP {
			ldap
		}
		Auth-Type PAP {
			pap
		}
		Auth-Type CHAP {
			chap
		}
		Auth-Type MS-CHAP {
			mschap
		}
		mschap
		digest
	}
	post-auth {
		ldap
		update {
			&reply: += &session-state:
		}
		exec
	}
}
EOF

cat << EOF > /etc/raddb/sites-enabled/inner-tunnel
server inner-tunnel {
	listen {
		   ipaddr = *
		   port = 18120
		   type = auth
	}
	authorize {
		ldap
		filter_username
		chap
		mschap
		suffix
		update control {
			&Proxy-To-Realm := LOCAL
		}
		files
		expiration
		logintime
		pap
	}
	authenticate {
		Auth-Type LDAP {
			ldap
		}
		Auth-Type PAP {
			pap
		}
		Auth-Type CHAP {
			chap
		}
		Auth-Type MS-CHAP {
			mschap
		}
		mschap
	}
	session {
		radutmp
	}
	post-auth {
		ldap
		if (0) {
			update reply {
				User-Name !* ANY
				Message-Authenticator !* ANY
				EAP-Message !* ANY
				Proxy-State !* ANY
				MS-MPPE-Encryption-Types !* ANY
				MS-MPPE-Encryption-Policy !* ANY
				MS-MPPE-Send-Key !* ANY
				MS-MPPE-Recv-Key !* ANY
			}
			update {
				&outer.session-state: += &reply:
			}
		}
		Post-Auth-Type REJECT {
			attr_filter.access_reject
			update outer.session-state {
				&Module-Failure-Message := &request:Module-Failure-Message
			}
		}
	}
}
EOF

/usr/sbin/radiusd -X
