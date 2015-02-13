#!/bin/bash

### for automatic 'apt-get install'
export DEBIAN_FRONTEND=noninteractive

IMAGE_CACHE_ROOT=/home/admin/share/imagecaches
ADDONS_ROOT=/home/admin/share/addons
INSTANCE_ROOT=/home/admin/share/instance
LXCDO_TAG=/home/admin/share/.lxcdo

RUNTIME_DIR=/home/admin/runtime
APP_DIR=/home/bae/app
LOG_DIR=/home/bae/log

function _exit() {
    rm -f $LXCDO_TAG
    exit $1    
}

function _error_exit() {
    _exit $1
}

function log()
{
    echo "$(date +%Y%m%d-%H%M%S): $@"
}

runtime_install()
{
    local runtime_type=$1
    local container_ip=$2
    local hostname=$3
    local uid=$4

    local image_dir=$IMAGE_CACHE_ROOT/$runtime_type
    chmod 700 /home/admin/share

    ### disable password login
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

    ### disable root login
    sed -i s#root:x:0:0:root:/root:/bin/bash#root:x:0:0:root:/root:/usr/sbin/nologin# /etc/passwd

    ### set root passwd
    local passwd=$(cat /dev/urandom | tr -dc "a-zA-Z0-9_+\~\!\@\#\$\%\^\&\*\(\)"| fold -w 20 |head -n 1)
    [ $? -eq 0 ] && {
        log "reset root password to ($passwd)"
        echo "root:$passwd" | chpasswd    
        [ $? -ne 0 ] && {
            log "reset password failed"
        }
    }

    echo "$container_ip $hostname" >> /etc/hosts

    [ "$uid" != "" ] && {
        log "change userid to $uid"
        groupmod -o -g $uid bae
        [ $? -ne 0 ] && {
            log "groupmod failed"
            _error_exit 1
        }
        usermod -o -u $uid -g $uid bae
        [ $? -ne 0 ] && {
            log "usermod failed"
            _error_exit 1
        }
        chown -R $uid:$uid /home/bae 
    
        local admin_uid=$(($uid+10000))
        groupmod -o -g $admin_uid admin
        usermod -o -u $admin_uid -g $admin_uid admin
        chown $admin_uid:$admin_uid /home/admin
    }

    log "deploy runtime"
    rm -rf $RUNTIME_DIR
    if [ -L $image_dir ]; then
        local real_path=$(readlink -e $image_dir)
        [ $? -ne 0 ] && {
            log "readlink $image_dir failed"
            _error_exit 1
        }
        if [ -d $real_path ]; then
            [ ! -d $real_path/runtime ] && {
                log "missing $real_path/runtime"
                _error_exit 1
            }
        
            cp -aRf $image_dir/runtime /home/admin
            [ $? -ne 0 ] && {
                log "deploy runtime failed"
                _error_exit 1
            }
        else
            tar xzf $real_path -C /home/admin/
            [ $? -ne 0 ] && {
                log "uncompress $realpath failed"
                _error_exit 1
            }
        fi
    else
        log "$image_dir must be a symbolic link"
        _error_exit 1
    fi

    log "post install"
    [ -f $RUNTIME_DIR/post_install.sh ] && {
        sh $RUNTIME_DIR/post_install.sh
        [ $? -ne 0 ] && {
            log "post_install failed"
            _error_exit 1
        }
    }

    [ ! -f $RUNTIME_DIR/run.sh ] && {
        log "missing $RUNTIME_DIR/run.sh"
        _error_exit 1
    }

    #log "setup profile"
    cp -f $INSTANCE_ROOT/bae_profile /home/bae/.bae_profile
    chown bae:bae /home/bae/.bae_profile

    touch /home/bae/.user_profile
    chown bae:bae /home/bae/.user_profile

    mkdir -p /home/bae/.ssh
    chown bae:bae /home/bae/.ssh
    chmod 700 /home/bae/.ssh

    log "deploy app code"
    rm -rf $APP_DIR
    cp -aR $INSTANCE_ROOT/app /home/bae/
    [ $? -ne 0 ] && {
        log "deploy app code failed"
        _error_exit 1
    }
    chown bae:bae -R $APP_DIR
    chown bae:bae -R $LOG_DIR
    chmod 777 $LOG_DIR
   
    cp -f $INSTANCE_ROOT/policy-rc.d /usr/sbin
    chmod +x /usr/sbin/policy-rc.d

    local conf=$APP_DIR/app.conf
    [ -f $conf ] && {
        python $INSTANCE_ROOT/handle_appconf.py $conf 0 $runtime_type
        local ret=$?
        [ $ret -ne 0 ] && {
            log "handle app config failed: $ret"
        }
    }

    [[ "$runtime_type" == "custom" && -f $APP_DIR/build_runtime.sh ]] && {
         log "run custom build"
         su -l bae -c "/bin/bash $APP_DIR/build_runtime.sh"
    }

    log "start runtime"    
    sh $RUNTIME_DIR/run.sh start
    _exit $?
}

function runtime_update()
{
    local runtime_type=$1
    local uid=$2

    local image_dir=$IMAGE_CACHE_ROOT/$runtime_type
    [ "$uid" != "" ] && {
        log "change userid to $uid"
        groupmod -o -g $uid bae
        [ $? -ne 0 ] && {
            log "groupmod failed"
            _error_exit 1
        }
        usermod -o -u $uid -g $uid bae
        [ $? -ne 0 ] && {
            log "usermod failed"
            _error_exit 1
        }
    }

    log "stop runtime"
    local retry=0
    while :
    do
        sh $RUNTIME_DIR/run.sh stop
        [ $? -eq 0 ] && { break; }
        retry=$(($retry+1))
        [ $retry -eq 3 ] && {
            sh $RUNTIME_DIR/run.sh start
            log "run stop failed"
            _error_exit 1
        }
        sleep 2
    done

    log "update runtime"
    rm -rf $RUNTIME_DIR
    if [ -L $image_dir ]; then
        local real_path=$(readlink -e $image_dir)
        [ $? -ne 0 ] && {
            log "readlink $image_dir failed"
            _error_exit 1
        }
        log "($real_path)"
        if [ -d $real_path ]; then
            [ ! -d $real_path/runtime ] && {
                log "missing $real_path/runtime"
                _error_exit 1
            }
            cp -aRf $image_dir/runtime /home/admin
            [ $? -ne 0 ] && {
                log "update runtime failed"
                _error_exit 1
            }
        else
            tar xzf $real_path -C /home/admin/
            [ $? -ne 0 ] && {
                log "uncompress $realpath failed"
                _error_exit 1
            }
        fi
    else
        log "$image_dir must be a symbolic link"
        _error_exit 1
    fi
    log "runtime update post install"
    [ -f $RUNTIME_DIR/post_install.sh ] && {
        sh $RUNTIME_DIR/post_install.sh
        [ $? -ne 0 ] && {
            log "runtime update post_install failed"
            _error_exit 1
        }
    }

    [ ! -f $RUNTIME_DIR/run.sh ] && {
        log "runtime update missing $RUNTIME_DIR/run.sh"
        _error_exit 1
    }

    chown bae:bae -R $APP_DIR
    chown bae:bae -R $LOG_DIR
    chmod 777 $LOG_DIR

    log "start runtime"
    sh $RUNTIME_DIR/run.sh start
}

function runtime_uninstall()
{
    [ -f $RUNTIME_DIR/run.sh ] && {
        sh $RUNTIME_DIR/run.sh stop
    } || {
        log "missing $RUNTIME_DIR/run.sh"
    }
    rm -rf $RUNTIME_DIR
    rm -rf $APP_DIR/*
}

function instance_start()
{
    if [ -f $RUNTIME_DIR/run.sh ]; then
        sh $RUNTIME_DIR/run.sh start
        [ $? -ne 0 ] && { log "start failed"; _exit 1; }
    else
        log "missing $RUNTIME_DIR/run.sh"
        _exit 1
    fi
}

function instance_stop()
{
    if [ -f $RUNTIME_DIR/run.sh ]; then
        sh $RUNTIME_DIR/run.sh stop
        [ $? -ne 0 ] && { log "stop failed"; _exit 1; }
    else
        log "missing $RUNTIME_DIR/run.sh"
        _exit 1
    fi
}

function instance_restart()
{
    if [ -f $RUNTIME_DIR/run.sh ]; then
        sh $RUNTIME_DIR/run.sh restart
        [ $? -ne 0 ] && { log "restart failed"; _exit 1; }
    else
        log "missing $RUNTIME_DIR/run.sh"
        _exit 1
    fi
}

function pre_app_update()
{
    if [ -f $RUNTIME_DIR/run.sh ]; then
        sh $RUNTIME_DIR/run.sh pre_app_update 
        [ $? -ne 0 ] && { log "pre_app_update failed"; _exit 1; }
    else
        log "missing $RUNTIME_DIR/run.sh"
        _exit 1
    fi
}

function resource_update()
{
    if [ -f $RUNTIME_DIR/run.sh ]; then
        sh $RUNTIME_DIR/run.sh resource_update 
    else
        log "missing $RUNTIME_DIR/run.sh"
        _exit 1
    fi
}

function app_update()
{
    local runtime_type=$1
    local conf=$APP_DIR/app.conf
    local oldmd5=""
    [ -f $conf ] && {
        oldmd5=$(md5sum $conf | awk '{print $1}')
    }

    local old_buildscript_md5=""
    [[ "$runtime_type" == "custom" && -f $APP_DIR/build_runtime.sh ]] && {
        old_buildscript_md5=$(md5sum $APP_DIR/build_runtime.sh |awk '{print $1}')
    }

    local exclude_file=/home/admin/share/instance/app/syncreserve.txt
    if [ -f $exclude_file ]; then
        rsync -aPtq --delete --exclude-from=$exclude_file /home/admin/share/instance/app/ $APP_DIR
    else
        rsync -aPtq --delete /home/admin/share/instance/app/ $APP_DIR
    fi
    [ $? -ne 0 ] && { log "app_update failed"; _exit 1; }
    chown bae:bae -R $APP_DIR

    [ -f $conf ] && {
        local newmd5=$(md5sum $conf | awk '{print $1}')
        if [ "$newmd5" != "$oldmd5" ]; then
            log "app config changed..."
            export DEBIAN_FRONTEND=noninteractive
            python $INSTANCE_ROOT/handle_appconf.py $conf 1 $runtime_type
            local ret=$?
            [ $ret -ne 0 ] && {
                log "handle app config failed: $ret"
            }
        fi
    }

    [[ "$runtime_type" == "custom" && -f $APP_DIR/build_runtime.sh ]] && {
         local new_buildscript_md5=$(md5sum $APP_DIR/build_runtime.sh |awk '{print $1}')
         if [ "$new_buildscript_md5" != "$old_buildscript_md5" ]; then
              log "run custom build"
              su -l bae -c "/bin/bash $APP_DIR/build_runtime.sh"
         fi
    }

}

function post_app_update()
{
    if [ -f $RUNTIME_DIR/run.sh ]; then
        sh $RUNTIME_DIR/run.sh post_app_update 
        [ $? -ne 0 ] && { log "post_app_update failed"; _exit 1; }
    else
        log "missing $RUNTIME_DIR/run.sh"
        _exit 1
    fi
}

touch $LXCDO_TAG
case C"$1" in
    Cruntime_install)
        shift 1
        runtime_install $*
        ;;
    Cruntime_update)
        shift 1
        runtime_update $*
        ;;
    Cruntime_uninstall)
        shift 1
        runtime_uninstall $*
        ;;
    Cinstance_start)
        shift 1
        instance_start $*
        ;;
    Cinstance_stop)
        shift 1
        instance_stop $*
        ;;
    Cinstance_restart)
        shift 1
        instance_restart $*
        ;;
    Cpre_app_update)
        shift 1
        pre_app_update $*
        ;;
    Cpost_app_update)
        shift 1
        post_app_update $*
        ;;
    Capp_update)
        shift 1
        app_update $*
        ;;
    Cresource_update)
        shift 1
        resource_update $*
        ;;
    C*)
        echo "unknow command ($1)"
        _exit 1
        ;;
esac
_exit 0

