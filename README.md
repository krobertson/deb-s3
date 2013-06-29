# deb-s3

`deb-s3` is a simple utility to make creating and managing APT repositories on
S3.

Most existing existing guides on using S3 to host an APT repository have you
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
  manifest.
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
  -a, [--arch=ARCH]              # The architecture of the package in the APT repository.
      [--sign=SIGN]              # Sign the Release file. Use --sign with your key ID to use a specific key.
  -p, [--preserve-versions]      # Whether to preserve other versions of a package in the repository when uploading one.
  -b, [--bucket=BUCKET]          # The name of the S3 bucket to upload to.
  -c, [--codename=CODENAME]      # The codename of the APT repository.
                                 # Default: stable
  -m, [--component=COMPONENT]    # The component of the APT repository.
                                 # Default: main
      [--access-key=ACCESS_KEY]  # The access key for connecting to S3.
                                 # Default: $AMAZON_ACCESS_KEY_ID
      [--secret-key=SECRET_KEY]  # The secret key for connecting to S3.
                                 # Default: $AMAZON_SECRET_ACCESS_KEY
      [--endpoint=ENDPOINT]      # The region endpoint for connecting to S3.
  -v, [--visibility=VISIBILITY]  # The access policy for the uploaded files. Can be public, private, or authenticated.
                                 # Default: public

Uploads the given files to a S3 bucket as an APT repository.
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
  -f, [--fix-manifests]          # Whether to fix problems in manifests when verifying.
  -b, [--bucket=BUCKET]          # The name of the S3 bucket to upload to.
  -c, [--codename=CODENAME]      # The codename of the APT repository.
                                 # Default: stable
  -m, [--component=COMPONENT]    # The component of the APT repository.
                                 # Default: main
      [--access-key=ACCESS_KEY]  # The access key for connecting to S3.
                                 # Default: $AMAZON_ACCESS_KEY_ID
      [--secret-key=SECRET_KEY]  # The secret key for connecting to S3.
                                 # Default: $AMAZON_SECRET_ACCESS_KEY
      [--endpoint=ENDPOINT]      # The region endpoint for connecting to S3.
  -v, [--visibility=VISIBILITY]  # The access policy for the uploaded files. Can be public, private, or authenticated.
                                 # Default: public

Verifies that the files in the package manifests exist
```

## TODO

This is still experimental.  These are several things to be done:

* Don't re-upload a package if it already exists and has the same hashes.
