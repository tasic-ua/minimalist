# minimalist
minimal but working mail list manager

## A few words at the start
The history of this MLM (mail list manager) starts from 90-s. Volodymyr Litovka created MLM with Perl without any external libraries. When I needed an MLM, I tried it, but as time passed, it could not correctly parse mail headers and work with utf-8. So I rewrote the old code with the help of sundry libraries but kept the logic of the code and config file. Of course, I extended the config file but kept backward compatibility and minimalist can work with the old config.

The MLM is really minimal. There is no web interface and many other features. But it still is powerful enough and easy to install and use.

## Contents
- **minimalist.pl** -- MLM
- **minimalist.conf** == config file with inline comments that help to make your config
- **README.md** -- you read me

## Installation

To run the MLM you have to have Perl version 5.* installed on your server. I believe that the libraries used by this program have more strict demands of the Perl version so if you can install the libraries the MLM will work. :)

minimalist.pl is looking for Perl on /usr/local/bin/perl. If your system has perl at another location you can make a symlink or change the path to the interpreter in the first line of the code.

To run the MLM you have to have the following modukes installed on your server:
- Fcntl - load the C Fcntl.h defines
- Mail::Header - manipulate MIME headers
- Encode - character encodings in Perl
- Mail::Address - parse mail addresses
- Config::Simple - simple configuration file class
- POSIX - Perl interface to IEEE Std 1003.1

Mail:Header and Mail:Address are the parts of the MailTools module on CPAN https://metacpan.org/release/MailTools

Config:Simple - is a module from CPAN http://search.cpan.org/dist/Config-Simple/

minimalist.pl usually has the global config file, and besides that, it can have a local config file for each mail list. The global config file is named minimalist.conf and the executable program is looking for it at /usr/local/etc/minimalist.conf (location of the config file as many other parameters you can see with "/usr/local/etc/minimalist.pl -"). The config file in this package contains all possible options documented inline there. Edit it according to your demands and put it at /usr/local/etc/minimalist.conf. Global config can be placed at another location, in this case, you have to run the program with the "-c" option pointed to the location of the global config file.

The files used to manage each mail list are placed at /var/spool/minimalist. You can change the location in the global config file. You must create this directory and make its owner the user used to run the MTA.

The /var/spool/maximalist may contain file lists.lst which contains the list of addresses of mail lists from the server that a user can subscribe to. The file is sent in reply to the info request.

Now the minimalist MLM is installed on a server. But to complete the installation i.e. to setup some mail list we need to fulfil more setup. Let;s say we want to setup mail list test-me@example.com on the server that support mail for the example.com domain.

First of all. in the directory /var/spool/minimalist/ we create directory matched the name of mail list. In our case it is test-me. The user from which the MTA is runnung must be the owner of this directory with the full rights.

The directory must contain the file named 'list'. The file contains the list of emails of members of mail list -- each address in a new line. The file can contain comments started from the #sign. The directory can contain a file 'list-writers' that contains addresses which can post to the mail list but do not receive messages from this mail list.


  
