#!/bin/bash

SEED=''
DEPTH='17'
TICK='15000'
apt update

apt install pkg-config zip g++ zlib1g-dev unzip python -y
wget https://github.com/bazelbuild/bazel/releases/download/0.18.0/bazel-0.18.0-installer-linux-x86_64.sh
chmod +x bazel-0.18.0-installer-linux-x86_64.sh
./bazel-0.18.0-installer-linux-x86_64.sh

apt install apt-transport-https ca-certificates curl software-properties-common docker.io jq -y

git clone https://github.com/iotaledger/compass.git
cd compass

echo
echo "-----
[=] Building the layers_calculator tool that'll create the Merkle tree...
-----"
echo

bazel run //docker:layers_calculator

echo
echo "-----
[=] Building the compass container image...
-----"
echo

bazel run //docker:coordinator

echo
echo "-----
[=] Here's your seed:
-----"
echo

if [ -z "$SEED" ]; then
  SEED=$(cat /dev/urandom |LC_ALL=C tr -dc 'A-Z9' | fold -w 81 | head -n 1)
  echo $SEED
fi

echo
echo

cd docs/private_tangle

jq -r '.seed = $seed' --arg seed $SEED config.example.json > config.json
jq -r '.depth = $depth' --argjson depth $DEPTH config.json > tmp.json && mv tmp.json config.json
jq -r '.tick = $tick' --argjson tick $TICK config.json > tmp.json && mv tmp.json config.json

echo "[=] Displaying configuration file:"
cat config.json

./01_calculate_layers.sh
echo 'FJHSSHBZTAKQNDTIKJYCZBOZDGSZANCZSWCNWUOCZXFADNOQSYAHEJPXRLOVPNOQFQXXGEGVDGICLMOXX;2779530283277761' > snapshot.txt

cat <<EOF > 02b_run_iri_service.sh
#!/bin/bash
. lib.sh
scriptdir='.'

load_config

COO_ADDRESS=\$(cat data/layers/layer.0.csv)

mkdir -p /mnt/iri
cp -r db /mnt/iri
cp -r snapshot.txt /mnt/iri

cat <<EOT > /etc/systemd/system/iri.service
[Unit]
Description=IRI
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
Restart=always
ExecStartPre=-/usr/bin/docker rm %n
ExecStart=/usr/bin/docker run -t --net host --rm --name iri.service -v /mnt/iri/db:/iri/data -v /mnt/iri/snapshot.txt:/snapshot.txt iotaledger/iri:latest \\\\
--testnet true \\\\
--remote true \\\\
--testnet-coordinator \$COO_ADDRESS \\\\
--testnet-coordinator-security-level \$security \\\\
--testnet-coordinator-signature-mode \$sigMode \\\\
--mwm \$mwm \\\\
--milestone-start \$milestoneStart \\\\
--milestone-keys \$depth \\\\
--snapshot /snapshot.txt \\\\
--max-depth 1000
[Install]
WantedBy=multi-user.target       
EOT

systemctl enable iri.service
systemctl start iri.service
EOF

chmod +x 02b_run_iri_service.sh
./02b_run_iri_service.sh

while ! $(nc -z localhost 14265); do
	echo
	echo "-----
[=] Waiting for node to start....
-----"
	echo

	sleep 5
done

cat <<EOF > 03b_run_coordinator_service.sh
#!/bin/bash

scriptdir='.'
. lib.sh

load_config


if [ ! -z "\$1" ]; then 
	echo LOL
	cp -r data /mnt/iri
fi

cat <<EOT > /etc/systemd/system/compass.service
[Unit]
Description=COMPASS
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
Restart=always
ExecStartPre=-/usr/bin/docker rm %n
ExecStart=/usr/bin/docker run -t --net host --rm --name compass.service -v /mnt/iri/data:/data iota/compass/docker:coordinator coordinator_deploy.jar \\\\
	-layers /data/layers \\\\
	-statePath /data/compass.state \\\\
	-sigMode \$sigMode \\\\
	-powMode \$powMode \\\\
	-mwm \$mwm \\\\
	-security \$security \\\\
	-seed \$seed \\\\
	-tick \$tick \\\\
	-host \$host \\\\
	-broadcast \$1

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
if [ ! -z "\$1" ]; then
	echo BOOTSTRAP
	systemctl enable compass.service
	systemctl start compass.service
else
	echo \$1
	systemctl restart compass.service
fi
EOF

chmod +x 03b_run_coordinator_service.sh

echo
echo "-----
[=] Bootstrapping compass...
-----"
echo

./03b_run_coordinator_service.sh -bootstrap

sleep 7

echo
echo "-----
[=] Restarting compass...
-----"
echo

./03b_run_coordinator_service.sh
