# deb-s3

[![Build Status](https://travis-ci.org/krobertson/deb-s3.svg?branch=master)](https://travis-ci.org/krobertson/deb-s3)

**This repository is no longer maintained.** I am no longer actively maintaining
deb-s3. I haven't been using it to maintain any repositories since
~2016. Someone had expressed interest in taking over development, but they
appear to be inactive with it as well.

`deb-s3` is a simple utility to make creating and managing APT repositories on
S3.

Most existing guides on using S3 to host an APT repository have you
using something like [reprepro](http://mirrorer.alioth.debian.org/) to generate
the repository file structure, and then [s3cmd](http://s3tools.org/s3cmd) to
sync the files to S3.

The annoying thing about this process is it requires you to maintain a local
copy of the file tree for regenerating and syncing the next time. Personally,
my process is to use one-off virtual machines with
[Vagrant](http://vagrantup.com), script out the build process, and then would
prefer to just upload the final `.deb` from my Mac.

With `deb-s3`, there is no need for this. `deb-s3` features:

* Downloads the existing package manifest and parses it.
* Updates it with the new package, replacing the existing entry if already
  there or adding a new one if not.
* Uploads the package itself, the Packages manifest, and the Packages.gz
  manifest. It will skip the uploading if the package is already there.
* Updates the Release file with the new hashes and file sizes.

## Getting Started

You can simply install it from rubygems:

```console
$ gem install deb-s3
```

Or to run the code directly, just check out the repo and run Bundler to ensure
all dependencies are installed:

```console
$ git clone https://github.com/krobertson/deb-s3.git
$ cd deb-s3
$ bundle install
```

Now to upload a package, simply use:

```console
$ deb-s3 upload --bucket my-bucket my-deb-package-1.0.0_amd64.deb
>> Examining package file my-deb-package-1.0.0_amd64.deb
>> Retrieving existing package manifest
>> Uploading package and new manifests to S3
   -- Transferring pool/m/my/my-deb-package-1.0.0_amd64.deb
   -- Transferring dists/stable/main/binary-amd64/Packages
   -- Transferring dists/stable/main/binary-amd64/Packages.gz
   -- Transferring dists/stable/Release
>> Update complete.
```

```
Usage:
  deb-s3 upload FILES

Options:
  -a, [--arch=ARCH]                                        # The architecture of the package in the APT repository.
  -p, [--preserve-versions], [--no-preserve-versions]      # Whether to preserve other versions of a package in the repository when uploading one.
  -l, [--lock], [--no-lock]                                # Whether to check for an existing lock on the repository to prevent simultaneous updates
      [--fail-if-exists], [--no-fail-if-exists]            # Whether to overwrite any existing package that has the same filename in the pool or the same name and version in the manifest but different contents.
      [--skip-package-upload], [--no-skip-package-upload]  # Whether to skip all package uploads.This is useful when hosting .deb files outside of the bucket.
  -b, [--bucket=BUCKET]                                    # The name of the S3 bucket to upload to.
      [--prefix=PREFIX]                                    # The path prefix to use when storing on S3.
  -o, [--origin=ORIGIN]                                    # The origin to use in the repository Release file.
      [--suite=SUITE]                                      # The suite to use in the repository Release file.
  -c, [--codename=CODENAME]                                # The codename of the APT repository.
                                                           # Default: stable
  -m, [--component=COMPONENT]                              # The component of the APT repository.
                                                           # Default: main
      [--access-key-id=ACCESS_KEY_ID]                      # The access key for connecting to S3.
      [--secret-access-key=SECRET_ACCESS_KEY]              # The secret key for connecting to S3.
      [--s3-region=S3_REGION]                              # The region for connecting to S3.
                                                           # Default: us-east-1
      [--force-path-style], [--no-force-path-style]        # Use S3 path style instead of subdomains.
      [--proxy-uri=PROXY_URI]                              # The URI of the proxy to send service requests through.
  -v, [--visibility=VISIBILITY]                            # The access policy for the uploaded files. Can be public, private, or authenticated.
                                                           # Default: public
      [--sign=SIGN]                                        # GPG Sign the Release file when uploading a package, or when verifying it after removing a package. Use --sign with your GPG key ID to use a specific key (--sign=6643C242C18FE05B).
      [--gpg-options=GPG_OPTIONS]                          # Additional command line options to pass to GPG when signing.
  -e, [--encryption], [--no-encryption]                    # Use S3 server side encryption.
  -q, [--quiet], [--no-quiet]                              # Doesn't output information, just returns status appropriately.
  -C, [--cache-control=CACHE_CONTROL]                      # Add cache-control headers to S3 objects.

Uploads the given files to a S3 bucket as an APT repository.
```

You can also delete packages from the APT repository. Please keep in mind that
this does NOT delete the .deb file itself, it only removes it from the list of
packages in the specified component, codename and architecture.

Now to delete the package:
```console
$ deb-s3 delete my-deb-package --arch amd64 --bucket my-bucket --versions 1.0.0
>> Retrieving existing manifests
   -- Deleting my-deb-package version 1.0.0
>> Uploading new manifests to S3
   -- Transferring dists/stable/main/binary-amd64/Packages
   -- Transferring dists/stable/main/binary-amd64/Packages.gz
   -- Transferring dists/stable/Release
>> Update complete.
```

```
Usage:
  deb-s3 delete PACKAGE

Options:
  -a, [--arch=ARCH]                                  # The architecture of the package in the APT repository.
      [--versions=one two three]                     # The space-delimited versions of PACKAGE to delete. If not specified, ALL VERSIONS will be deleted. Fair warning. E.g. --versions "0.1 0.2 0.3"
  -b, [--bucket=BUCKET]                              # The name of the S3 bucket to upload to.
      [--prefix=PREFIX]                              # The path prefix to use when storing on S3.
  -o, [--origin=ORIGIN]                              # The origin to use in the repository Release file.
      [--suite=SUITE]                                # The suite to use in the repository Release file.
  -c, [--codename=CODENAME]                          # The codename of the APT repository.
                                                     # Default: stable
  -m, [--component=COMPONENT]                        # The component of the APT repository.
                                                     # Default: main
      [--access-key-id=ACCESS_KEY_ID]                # The access key for connecting to S3.
      [--secret-access-key=SECRET_ACCESS_KEY]        # The secret key for connecting to S3.
      [--s3-region=S3_REGION]                        # The region for connecting to S3.
                                                     # Default: us-east-1
      [--force-path-style], [--no-force-path-style]  # Use S3 path style instead of subdomains.
      [--proxy-uri=PROXY_URI]                        # The URI of the proxy to send service requests through.
  -v, [--visibility=VISIBILITY]                      # The access policy for the uploaded files. Can be public, private, or authenticated.
                                                     # Default: public
      [--sign=SIGN]                                  # GPG Sign the Release file when uploading a package, or when verifying it after removing a package. Use --sign with your GPG key ID to use a specific key (--sign=6643C242C18FE05B).
      [--gpg-options=GPG_OPTIONS]                    # Additional command line options to pass to GPG when signing.
  -e, [--encryption], [--no-encryption]              # Use S3 server side encryption.
  -q, [--quiet], [--no-quiet]                        # Doesn't output information, just returns status appropriately.
  -C, [--cache-control=CACHE_CONTROL]                # Add cache-control headers to S3 objects.

Remove the package named PACKAGE. If --versions is not specified, deleteall versions of PACKAGE. Otherwise, only the specified versions will be deleted.
```

You can also verify an existing APT repository on S3 using the `verify` command:

```console
deb-s3 verify -b my-bucket
>> Retrieving existing manifests
>> Checking for missing packages in: stable/main i386
>> Checking for missing packages in: stable/main amd64
>> Checking for missing packages in: stable/main all
```

```
Usage:
  deb-s3 verify

Options:
  -f, [--fix-manifests], [--no-fix-manifests]        # Whether to fix problems in manifests when verifying.
  -b, [--bucket=BUCKET]                              # The name of the S3 bucket to upload to.
      [--prefix=PREFIX]                              # The path prefix to use when storing on S3.
  -o, [--origin=ORIGIN]                              # The origin to use in the repository Release file.
      [--suite=SUITE]                                # The suite to use in the repository Release file.
  -c, [--codename=CODENAME]                          # The codename of the APT repository.
                                                     # Default: stable
  -m, [--component=COMPONENT]                        # The component of the APT repository.
                                                     # Default: main
      [--access-key-id=ACCESS_KEY_ID]                # The access key for connecting to S3.
      [--secret-access-key=SECRET_ACCESS_KEY]        # The secret key for connecting to S3.
      [--s3-region=S3_REGION]                        # The region for connecting to S3.
                                                     # Default: us-east-1
      [--force-path-style], [--no-force-path-style]  # Use S3 path style instead of subdomains.
      [--proxy-uri=PROXY_URI]                        # The URI of the proxy to send service requests through.
  -v, [--visibility=VISIBILITY]                      # The access policy for the uploaded files. Can be public, private, or authenticated.
                                                     # Default: public
      [--sign=SIGN]                                  # GPG Sign the Release file when uploading a package, or when verifying it after removing a package. Use --sign with your GPG key ID to use a specific key (--sign=6643C242C18FE05B).
      [--gpg-options=GPG_OPTIONS]                    # Additional command line options to pass to GPG when signing.
  -e, [--encryption], [--no-encryption]              # Use S3 server side encryption.
  -q, [--quiet], [--no-quiet]                        # Doesn't output information, just returns status appropriately.
  -C, [--cache-control=CACHE_CONTROL]                # Add cache-control headers to S3 objects.

Verifies that the files in the package manifests exist
```
