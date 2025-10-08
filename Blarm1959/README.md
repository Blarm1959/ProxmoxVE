root ssh
passwd root
sudo vi /etc/ssh/sshd_config
#PermitRootLogin prohibit-password
PermitRootLogin yes
sudo systemctl restart ssh

dispatcharr_downgrade.sh
sudo chmod +x ./dispatcharr_downgrade.sh
sudo ./dispatcharr_downgrade.sh --ver v0.10.2
