# @summary Add firewalld rules with various safety checks
#
# @param trusted_nets
#   The networks/hosts to which the rule applies
#
# @param protocol
#   The network protocol to which the rule applies
#
# @param dports
#   The ports to which the rule applies
#
# @param icmp_blocks
#   The ICMP Blocks to which the rule applies
#
# @param order
#   The order in which the rule should appear
#
#   Due to the way firewalld works, this may not do what you expect unless the
#   version of firewalld explicitly supports it.
#
#   * 1 is the minimum and 9999999 is the maximum
#
#   * The following ordering ranges are suggested (but not enforced):
#
#       * 1     -> ESTABLISHED,RELATED rules
#       * 2-5   -> Standard ACCEPT/DENY rules
#       * 6-10  -> Jumps to other rule sets
#       * 11-20 -> Pure accept rules
#       * 22-30 -> Logging and rejection rules
#
# @param apply_to
#   The address family to which to apply this rule
#
#   * ipv4 -> iptables
#   * ipv6 -> ip6tables
#   * all  -> Both
#   * auto -> Try to figure it out from the rule, defaults to ``all``
#
# @param prefix
#   This will be prepended to all created components
#
#   * This is important for being able to tidy rules later on.
#   * Will default to `$simp_firewalld::tidy_prefix` if set and `simp_` otherwise
#
# @param zone
#   The zone to which to apply the rule
#
#   * Will default to `$simp_firewalld::default_zone` if set and `99_simp` otherwise
#
define simp_firewalld::rule (
  Enum['ah', 'esp', 'icmp', 'tcp', 'udp', 'all'] $protocol,
  Simplib::Netlist                               $trusted_nets  = simplib::lookup('simp_options::trusted_nets', { 'default_value' => ['127.0.0.1'] }),
  Optional[Simp_firewalld::DestPort]             $dports        = undef,
  Optional[Variant[Array[String],String]]        $icmp_blocks   = undef,
  Integer[0]                                     $order         = 11,
  Simp_firewalld::ApplyTo                        $apply_to      = 'auto',
  Optional[String[1]]                            $prefix        = undef,
  Optional[String[1]]                            $zone          = undef,
) {
  include simp_firewalld

  if $simp_firewalld::enable {
    if $prefix {
      $_prefix = $prefix
    }
    else {
      $_prefix = pick($simp_firewalld::tidy_prefix, 'simp_')
    }

    if $zone {
      $_zone = $zone
    }
    else {
      $_zone = pick($simp_firewalld::default_zone, '99_simp')
    }

    $_safe_name = regsubst($name, '[^\w-]', '_', 'G')

    if $protocol == 'icmp' {
      $_dports = undef
      $_icmp_block = Array($icmp_blocks)
    }
    elsif $protocol in ['ah', 'esp'] {
      $_dports = undef
    }
    else {
      if $dports {
        $_dports_a = Array($dports, true)
        $_dports = $_dports_a.map |$dport| {
          # Convert all IPTables range formats over to firewalld formats
          $_converted_port = regsubst("${dport}",':','-') # lint:ignore:only_variable_string

          if $protocol != 'all' {
            {
              'port'     => $_converted_port,
              'protocol' => $protocol
            }
          }
          else {
            {
              'port' => $_converted_port
            }
          }
        }

        firewalld::custom_service { "${_prefix}${_safe_name}":
          short       => "${_prefix}${name}",
          description => "SIMP ${name}",
          port        => $_dports,
          require     => Service['firewalld'],
        }
      }
      else {
        $_dports = undef
      }
    }

    $_trusted_nets = Array($trusted_nets, true)

    # These cases indicate that only a service should be added to the zone and
    # not an ipset since it will allow from anywhere and the rest of the
    # matches are irrelevant at that point.
    if ['0.0.0.0/0', '::/0', '[::]/0', 'ALL', 'any'].any |$x| { $x in $_trusted_nets } {
      $_allow_from_all = true
    }
    else {
      $_allow_from_all = false
    }

    # It only makes sense to create this if we have been passed some ports to
    # bind it to.
    if $_dports and $_allow_from_all {
      firewalld_service { "${_prefix}${_safe_name}":
        zone    => $_zone,
        require => Service['firewalld'],
      }
    }
    else {
      if $_allow_from_all {
        if ($apply_to == 'ipv4') {
          $_trusted_nets_hash = simplib::ip::family_hash(['0.0.0.0/0'])
        }
        elsif ($apply_to == 'ipv6') {
          $_trusted_nets_hash = simplib::ip::family_hash(['::/0'])
        }
        else {
          $_trusted_nets_hash = simplib::ip::family_hash(['0.0.0.0/0', '::/0'])
        }
      }
      else {
        $_tmp_nets_hash = simplib::ip::family_hash($_trusted_nets)

        if $_tmp_nets_hash['unknown'] {

          $_msg_string = join($_tmp_nets_hash['unknown'].keys, ', ')

          notify { "${module_name}::rule[${_safe_name}] - hostname warning":
            message  => "Firewalld cannot handle hostnames and the following were found in 'trusted_nets': '${_msg_string}'",
            withpath => true,
            loglevel => 'warning',
          }
        }

        $_trusted_nets_hash = $_tmp_nets_hash.delete('unknown')
      }

      # We need to perform the correct action based on each IP Address family
      # in the $_trusted_nets Array
      $_trusted_nets_hash.keys.each |$_ip_family| {
        # Only activate on the correct type of IP address
        if ($apply_to == 'all') or ($apply_to == 'auto') or ($apply_to == $_ip_family) {

          # Determine what can go into an IPSet and what can't
          $_split_entries = $_trusted_nets_hash[$_ip_family].reduce({'hash:ip' => [], 'hash:net' => []}) |$memo, $x| {
            $_data = $x[-1]
            if (($_ip_family == 'ipv4') and ($_data['netmask']['cidr'] == 32)) or
              (($_ip_family == 'ipv6') and ($_data['netmask']['cidr'] == 128)) {
              {
                # firewall-cmd can't handle bracketed addresses for IPv6
                'hash:ip'  => $memo['hash:ip'] + $_data['address'],
                'hash:net' => $memo['hash:net']
              }
            }
            else {
              {
                'hash:ip'  => $memo['hash:ip'],
                'hash:net' => $memo['hash:net'] + "${_data['address']}/${_data['netmask']['cidr']}"
              }
            }
          }

          # Create unique ipsets based on the bare addresses and ranges
          #
          # This is done so that we do not end up with a million rules for every
          # call and so that we can reuse as many ipsets as possible.
          #
          # The length is limited due to apparent limitations in the ipset name
          #
          # The firewalld_ipset type should probably be updated to do "the
          # right thing" if it can figure it out
          #
          $_split_entries.each |$_ipset_type, $_ipset_entries| {
            unless empty($_ipset_entries) {
              $_ipset_family = $_ip_family ? { 'ipv6' => 'inet6', default => 'inet' }

              $_ipset_name = join(
                [
                  'simp',
                  seeded_rand_string(
                    26,
                    join([$_ipset_family, $_ipset_type] + sort(unique($_trusted_nets)),'')
                  )
                ], '-')[0,31]


              if $_allow_from_all {
                $_source = $_ipset_entries[0]
              }
              else {
                $_source = { 'ipset' => $_ipset_name }

                ensure_resource('firewalld_ipset', $_ipset_name,
                  {
                    'entries' => $_ipset_entries,
                    'type'    => $_ipset_type,
                    'options' => {
                      'family' => $_ipset_family,
                    },
                    require   => Service['firewalld'],
                  }
                )
              }

              # We need this because the underlying types can't handle Arrays
              $_unique_name = regsubst(
                  join([
                    'simp',
                    $order,
                    $_safe_name,
                    $_ipset_name,
                  ], '_'),
                '_+', '_', 'G')

              if $protocol == 'icmp' {
                firewalld_rich_rule { $_unique_name:
                  ensure     => 'present',
                  family     => $_ip_family,
                  source     => $_source,
                  icmp_block => $_icmp_block,
                  action     => 'accept',
                  zone       => $_zone,
                  require    => Service['firewalld'],
                }
              }
              elsif $protocol in ['ah', 'esp'] {
                firewalld_rich_rule { $_unique_name:
                  ensure   => 'present',
                  family   => $_ip_family,
                  source   => $_source,
                  action   => 'accept',
                  zone     => $_zone,
                  protocol => $protocol,
                  require  => Service['firewalld'],
                }
              }
              else {
                # If we don't have any ports, then we don't have a service to
                # bind to. This probably means that we were called in a way to
                # allow all traffic to a specific IP address.
                if $_dports {
                  $_rich_rule_svc = "${_prefix}${_safe_name}"
                }
                else {
                  $_rich_rule_svc = undef
                }

                firewalld_rich_rule { $_unique_name:
                  ensure  => 'present',
                  family  => $_ip_family,
                  source  => $_source,
                  service => $_rich_rule_svc,
                  action  => 'accept',
                  zone    => $_zone,
                  require => Service['firewalld']
                }

                # Work around bug in puppet-firewalld
                if $_rich_rule_svc {
                  Firewalld_custom_service[$_rich_rule_svc] -> Firewalld_rich_rule[$_unique_name]
                }
              }
            }
          }
        }
      }
    }
  }
  else {
    warning("${module_name}::rule[${name}] will not be enabled since the ${module_name} class has been disabled")
  }
}
