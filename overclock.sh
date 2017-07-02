#!/bin/bash

# Overclocking script for trihard
# DO NOT USE ON OTHER BOXES!

# TRIHARD -- 3 x EVGA GTX 1060 6GB

#EVGA 1060 6gb stock mem clock 8008MHz
#We aim for 9500ish Mhz mem clock.

VALID_HOST=trihard
CARDS=3
CARD0_MEMOFFSET=1500 
CARD1_MEMOFFSET=1500 #this card can't hack it @ 1500
CARD2_MEMOFFSET=1500

#Check this script is running on the right host
if [ `hostname` != $VALID_HOST ] ; then
	echo "RUNNING THIS SCRIPT ON THE WRONG HOST YOU IDIOT YOU COULD HAVE BRICKED YOUR RIG"
	exit 99
fi


#Nvidia-settings needs xorg to be running. 
pgrep -a Xorg > /dev/null
if [ $? -ne 0 ] ; then
	echo "Xorg isn't running... start it before trying to overclock"
	exit 1
fi

#Get the display number.. this is abit of a hack and might not work all the time
export DISPLAY=`pgrep -a Xorg | cut -d ' ' -f 3 | head -n1`
echo "Found DISPLAY=$DISPLAY"

#Check if display at least looks valid
VALID_DISPLAYS=(:0 :1 :2 :3 :4 :5 :6 :7)
isvalid=notvalid
for display in "${VALID_DISPLAYS[@]}"
do
	if [ $DISPLAY == $display ] ; then
		#Got a match, we can break this loop
		isvalid=yessirr
		break
	fi
done

if [ $isvalid == 'notvalid' ] ; then
	echo "$DISPLAY is not a valid DISPLAY.. restart xorg?"
	exit 1
fi

#Display looks valid, check we have the right number of cards
DETECTED_CARDS=`nvidia-smi --query-gpu=name --format=csv,noheaders | wc -l`

if [ $DETECTED_CARDS == $CARDS ] ; then
	echo "Configuring for $CARDS cards but detected $DETECTED_CARDS cards"
	exit 2
fi

#Check nvidia-settings works with this display value
export DISPLAY
TEST_NVIDIA_CMD="nvidia-settings -q CurrentMetaMode"
$TEST_NVIDIA_CMD > /dev/null 2>&1

if [ $? -ne 0 ] ; then
	echo "nvidia-settings failed with exit code $?"
	echo "To see error, run '$TEST_NVIDIA_CMD'"
fi

#Iterate through our cards and overclock each one correctly.
#If the overclock fails, notify the user (or something)
for (( i=0;i<$CARDS;i++)) ; do
	#Some bash fuckery to use dynamic variable names
	memoffset=CARD${i}_MEMOFFSET
	cmd="nvidia-settings -c $DISPLAY -a [gpu:$i]/GPUMemoryTransferRateOffset[3]=${!memoffset}"
	echo "Running $cmd"
	#Run the cmd
	#TODO

	#Check it exited correctly
	if [ $? -ne 0 ] ; then
		echo "---- WARNING WARNING WARNING WARNING WARNING -----"
		echo "Failed to overclock GPU{i}...."
	fi
done

#nvidia-settings -c :1 -a [gpu:1]/GPUMemoryTransferRateOffset[3]=1500
