# kasten-wizard-v2
Auto deploy Kasten in ubuntu VM.

If running on VM config virtualization capabilities:
Expose hardware assisted virtualization to the guest OS

In linux validate KVM:
egrep -c '(vmx|svm)' /proc/cpuinfo

Then do git clone.

make files executable:
chmod -R +x *

Go to v2 folder:
cd kasten-wizard-v2/v2/

Run install:
sudo ./install.sh

Wait to finish.