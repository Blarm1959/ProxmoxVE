root ssh
passwd root
sudo vi /etc/ssh/sshd_config
#PermitRootLogin prohibit-password
PermitRootLogin yes
sudo systemctl restart ssh

force_version.sh
sudo chmod +x ./force_version.sh
sudo ./force_version.sh (for 0.0.0 or sudo ./force_version.sh --version v0.10.2 or sudo ./force_version.sh -V 0.10.2)
