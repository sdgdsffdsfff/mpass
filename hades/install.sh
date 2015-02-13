source conf.sh

[ -d /home/bae/baeng/hades ] && {
	echo "stop current hades"
	/home/bae/baeng/hade/bin/control stop
	echo "backup current hades"
	now=
	mv /home/bae/baeng/hades /home/bae/baeng/hades.$now
}

echo "install new hades"
### copy it into /home/bae/baeng/hades

rm -f /usr/local/bin/wsh
ln -sf /home/bae/baeng/hades/docker/wsh /usr/local/bin/wsh


[ ! -f /root/.ssh/id_rsa.pub ] && {
	echo "generate ssh key of root"
	ssh-keygen
}

mkdir -p /home/bae/share/instances
mkdir -p /home/bae/share/logs
mkdir -p /home/bae/share/ssh

chmod 700 /home/bae/share/ssh
cp -f /root/.ssh/id_rsa.pub /home/bae/share/ssh/authorized_keys
chmod 600 /home/bae/share/ssh/authorized_keys



##/etc/init.d/apparmor start

for server in $FILE_SERVERS
do
	ssh-copy-id -i /root/.ssh/id_rsa.pub $FILE_SERVER_USER@$server
done

apt-get install -y python-pip
cd /home/bae/baeng/hades/misc
tar xzf pika-0.9.13.tar.gz
cd pika-0.9.13
python ./setup.py install
cd ..
rm -rf pika-0.9.13

