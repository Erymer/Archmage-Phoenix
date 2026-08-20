# Archmage-Phoenix

Collection of scripts and ansible playbooks to do a fresh install of Archmage
without losing home partition.


# Testing

For testing follow these steps:

- Run `sudo ./tests/test-archmage-bootstrap.sh`
- In `./archmage-bootstrap.sh` check for the comments with the line `TESTING`
  and follow the instructions. These involve comment and uncomment so things.
  This is important, otherwise the script might delete everything in the current
  system
