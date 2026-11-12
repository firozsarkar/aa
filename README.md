```bash
curl -sL https://raw.githubusercontent.com/firozsarkar/aa/refs/heads/main/install.sh -o install-with-setup.sh
sed -i 's/iptables-persistent //g' install-with-setup.sh
chmod +x install-with-setup.sh
./install-with-setup.sh
```
