# Archmage-Phoenix 🧙‍♂️🔥

Archmage-Phoenix is an automated system bootstrap and maintenance tool designed
to reinstall and refresh Arch Linux environments without altering existing disk
partition layouts or disturbing user data. Powered by `archmage-bootstrap.sh`,
this project enables reproducible system maintenance and clean reinstalls while
keeping personal setups intact.


## 🎯 Purpose of `archmage-bootstrap.sh`

The primary goal of `archmage-bootstrap.sh` is to perform non-destructive system
maintenance by reinstalling the base environment with surgical precision:

- `/home` Directory Preservation: Restores system binaries and package configs
  without wiping or altering the user's home directory (`/home`), ensuring
  personal files, configs, and user settings remain untouched.
- Partition Layout Integrity: Reinstalls over existing installations without
  modifying or recreating the disk partition structure.
- System Maintenance & Refresh: Packages, repository states, and core system
  files are cleanly reinstalled to fix system degradation or drift.
- Automated Recovery: Eliminates the manual tediousness of post-installation
  maintenance into a single execution stream.


## 💾 Supported Disk Layout

Currently, `archmage-bootstrap.sh` is tailored to work specifically with the
following LUKS + LVM partition structure:

```
├─nvme0n1p5               /dev/nvme0n1p5               crypto_LUKS
│ └─archmage                 /dev/mapper/archmage         LVM2_member
│   ├─volgroup0-root root    /dev/mapper/volgroup0-root   /.snapshots btrfs
│   ├─volgroup0-var  var     /dev/mapper/volgroup0-var    /var        ext4
│   └─volgroup0-home home    /dev/mapper/volgroup0-home   /home       btrfs
```


## 🚀 Quick Start (Direct Terminal Execution)

You can run the bootstrap script directly from your terminal without cloning or
downloading the entire repository manually:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Erymer/Archmage-Phoenix/refs/heads/main/archmage-bootstrap.sh)
```

> Note: It is good security practice to inspect remote scripts prior to execution.
> You can view the raw script contents in your browser or run:
> 
> ```bash
> curl -sSL https://raw.githubusercontent.com/Erymer/Archmage-Phoenix/refs/heads/main/archmage-bootstrap.sh | less
> ```


## 📁 Repository Structure

```
Archmage-Phoenix/
├── archmage-bootstrap.sh          # Primary bootstrap and installation script
├── tests/
│   └── test-archmage-bootstrap.sh # Test runner script
├── LICENSE                        # Repository license
└── README.md                      # Project documentation
```


## 🧪 Running Tests

The repository includes a test harness (`tests/test-archmage-bootstrap.sh`) to
create a mock environment to test if the bootstrap script will preserve the
`/home` partition while formatting the root and `/var` partitions.


### `test-archmage-bootstrap.sh` — Loop Device Test Harness

Builds a fake LUKS+LVM+BTRFS/ext4 stack on loopback files that mirrors
`archmage-bootstrap.sh`'s expectations, so you can validate the format/mount
logic without touching real hardware.

- Run with: `sudo ./tests/test-archmage-bootstrap.sh`
- Clean up with: `sudo ./tests/test-archmage-bootstrap.sh clean`

To run tests, simply follow the instructions provided directly by the script
during execution, which involves commenting out specific commands or modifying
constants in `archmage-bootstrap.sh` as needed for your testing environment.
