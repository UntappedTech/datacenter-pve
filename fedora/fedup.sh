#!/bin/bash

VERSION="1.0"

USAGE="Usage: $0 [ -h | --help ] [ -v | --version ]

This script helps to automate the process of upgrading to newer versions of Fedora.
No arguments are expected as the script check to see which versions are available upgrade targets,
and then asks which version you would like to attempt to upgrade to.

If everything goes smoothly, the machine will automatically reboot when it is ready without further interaction.

Possible return values:
0:   Indicates that a flag was passed in and no actual operations were performed.
1:   Indicates that the system is already running the latest release of Fedora and no further action is required.
2:   Indicates that the user chose to abort the upgrade process.
100: Indicates that there are updates which need to be installed prior to running this script." 

#Print the help if requested
for OPTION in "$@"
do
	case $OPTION in
		-v|--version)
		echo "Version: $VERSION"
		exit 0;
		;;
		-h|--help)
		echo "Fedup, version: $VERSION"
		echo "$USAGE"
		exit 0;
		;;
	esac
done

# See if there are any updates on the system
dnf check-update

# If the system has updates, inform the user and exit
if [ $? != 0 ]; then
	echo "Please install updates and reboot if a new kernel is installed before proceeding"
	exit 100;
fi

# Get a list of all releases in RPMFusion
AvailableReleases=($(curl -s http://download1.rpmfusion.org/free/fedora/releases/ | grep -o '[0-9]\{1,2\}\/' | sed 's/\///' | uniq | tr "\n" " "))
CurrentRelease=$(cut -d ' ' -f 3 /etc/fedora-release)

let "LastIndex=(${#AvailableReleases[@]} - 1)"
CurrentReleaseIndex=0

for (( i=0; i<=$LastIndex; i++)); do
        if [ ${AvailableReleases[i]} -eq $CurrentRelease ];then
                CurrentReleaseIndex=$i
                break
        fi
done

if (( $CurrentReleaseIndex == $LastIndex )); then
        echo "It looks like you're all up to date"
        exit 1;
fi

NewerReleases=(${AvailableReleases[@]:$(expr $CurrentReleaseIndex + 1)})

echo "Available release target for the upgrade:"
echo "-----------------------------------------"

for (( j=0; j<${#NewerReleases[@]}; j++ )); do
        echo -e "$j) ${NewerReleases[j]}"
done

let "AvailableIndexes=(${#NewerReleases[@]} - 1)"
echo ""

number=""
while [[ -z $number ]]; do
    echo "Please choose a release version:"
    read number
	if (( $number < 0 || $number >= ${#NewerReleases[@]} )); then
		number=""
		echo "Must be in the range 0-$AvailableIndexes"
	fi
	echo ""
done

#echo $number

input=""
while [[ ! $input =~ [yYnN] ]]; do
    echo "Fedora will be upgraded to release version ${NewerReleases[$number]}"
	echo "Is this okay? [y/n]"
    read input
	echo ""
done

if [[ $input =~ [nN] ]]; then
	echo "Aborting"
	exit 2;
fi

dnf upgrade --refresh && dnf install -y dnf-plugin-system-upgrade && dnf -y system-upgrade download --refresh --releasever=${NewerReleases[$number]} && dnf system-upgrade reboot

