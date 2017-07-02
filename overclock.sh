#!/bin/bash
set -e
# expects a configuration file in the same directory contains a configuration for this box.
# Configuration file should be in the format: ${hostname}.oc.config
# Does minimal sanity checking on overclock settings, use with caution.


#IF HOSTNAME CONTAINS SPACES THIS WHOLE SCRIPT IS FUCKED
#MAKE SURE YOU HAVE $hostname.oc.config in the current directory

#The following MIN/MAX variables are absolute limits for this script.
#It will not overclock higher or lower than these values.
#If a configuration file contains a value outside of these ranges, script fails
#GPUTargetFanSpeed
MIN_FAN_SPEED=50
MAX_FAN_SPEED=100

#GPUMemoryTransferRateOffset
MIN_MEM_SPEED=0
MAX_MEM_SPEED=2000

#GPUPowerLimit ... These values are for GTX1060's
MAX_POWER_LIMIT=140
MIN_POWER_LIMIT=60

#GPUGraphicsClockOffset
MIN_CORE_CLOCK=-200
MAX_CORE_CLOCK=200

#GPUPowerMizer 
#All we really care about it PowerMizer=0, and it doesn't even work on 1060's..
#just here for completeness
MAX_POWER_MIZER=2
MIN_POWER_MIZER=0


#Not using nvidia-settings --load-config because you have to do some stuff with
#nvidia-smi (power limit, persistence mode)
CFG_FILE=$PWD/$HOSTNAME.oc.config

if ! [ -e "$CFG_FILE" ] ; then
    echo "No config file found for this host ($HOSTNAME)"
    exit 2
fi

#Now source the config file vars into our namespace
echo "Found configuration file $CFG_FILE"
source "$CFG_FILE"

#Check this script is running on the right host
if [ "$HOSTNAME" != "$VALID_HOST" ] ; then
	echo "RUNNING THIS SCRIPT ON THE WRONG HOST YOU IDIOT YOU COULD HAVE BRICKED YOUR RIG"
	exit 99
fi

#Nvidia-settings needs xorg to be running. 
if ! pgrep -a Xorg > /dev/null  ; then
	echo "Xorg isn't running... start it before trying to overclock"
	exit 1
fi

#Get the display number.. this is abit of a hack and might not work all the time
#BUG the column we cut the display number from dependson how we start X
#Through SSH -c, we need to get column 3
#Started "normally" (well, still through SSH but not as -c), column 5
#Just assume column 5 for now because it makes things easier
export DISPLAY=$(pgrep -a Xorg | cut -d ' ' -f 5 | head -n1)
echo "Found DISPLAY=$DISPLAY"

#Check if display at least looks valid
#Probably not needed
VALID_DISPLAYS=(:0 :1 :2 :3 :4 :5 :6 :7)
isvalid=notvalid
for display in "${VALID_DISPLAYS[@]}"
do
	if [ "$DISPLAY" == "$display" ] ; then
		#Got a match, we can break this loop
		isvalid=yessirr
		break
	fi
done

if [ $isvalid == 'notvalid' ] ; then
	echo "$DISPLAY is not a valid DISPLAY.. restart xorg or fix this script?"
	exit 1
fi

if ! $(which nvidia-settings &> /dev/null) ; then
    echo "nvidia-settings not installed..."
    exit 2
fi

#Display looks valid, check we have the right number of cards
DETECTED_CARDS=$(nvidia-smi --query-gpu=name --format=csv,noheaders | wc -l)

if [ "$DETECTED_CARDS" -ne "$CARDS" ] ; then
	echo "Configuring for $CARDS cards but detected $DETECTED_CARDS cards"
	exit 2
fi

#Check nvidia-settings works with this display value
export DISPLAY
TEST_NVIDIA_CMD="nvidia-settings -q CurrentMetaMode"

if ! $TEST_NVIDIA_CMD ; then
	echo "nvidia-settings failed with exit code $?"
    echo "It's probably an invalid DISPLAY.. we used $DISPLAY"
	echo "To see error in detail, run '$TEST_NVIDIA_CMD'"
    exit 2
fi

## ===---===---=== OVERCLOCKING FUNCTIONS ===---===---=== ##
### Function which setups the fans using the configuration file already sourced
# $1 - GPUID we are configuring fans for
function setup_fans {
    gpuid=$1

    enable_fan=${GPUFanControlState[gpuid]} 
    #Unless enable_fan is 1 just leave it to be automatically controlled
    if [ "$enable_fan" == 1 ] ; then
        target_fan_speed=${GPUTargetFanSpeed[$gpuid]}

        #Check it's an integer
        if [ "$target_fan_speed" -eq "$target_fan_speed" ] 2> /dev/null ; then
            #It's an integer.. we can continue
            :
        else
            echo "The given GPUTargetFanSpeed isn't even an integer. Fix your config"
            echo "Passed: $target_fan_speed"
            exit 5
        fi

        #Check it's not 0 and give a special message to that user
        if [ "$target_fan_speed" -eq 0 ] ; then
            echo "Stupidity Detected.. Setting target_fan_speed to 0 will more than likely overheat your card... remove this check if you really want to do that"
            exit 5
        fi

        #Now check the target fan speed is an integer between MIN_FAN and MAX_FAN
        #You can change these variables at the top of this script
        if ! [ "$target_fan_speed" -ge "$MIN_FAN_SPEED" -a "$target_fan_speed" -le "$MAX_FAN_SPEED" ] ; then
            echo "Given GPUTargetFanSpeed for GPU${gpuid} is incorrect"
            echo "Should be >= $MIN_FAN_SPEED and <= $MAX_FAN_SPEED"
            echo "Got $target_fan_speed"
            exit 5
        fi

        enable_fan_cmd="nvidia-settings -c "$DISPLAY" -a [gpu:"$gpuid"]/GPUFanControlState=1"
        fan_speed_cmd="nvidia-settings -c "$DISPLAY" -a [fan:"$gpuid"]/GPUTargetFanSpeed=${GPUTargetFanSpeed[$gpuid]}"

        echo -n "GPU${gpuid} fan speed $target_fan_speed"
        echo "  $enable_fan_cmd"
        echo "  $fan_speed_cmd"
    else
        echo -n "GPU${gpuid} autofan"
    fi
}

### Function which setups the memory clock speed using the configuration file sourced
#$1 - GPU to overclock memory for
function setup_mem_clock {
    gpuid=$1
    target_speed=${GPUMemoryTransferRateOffset[$gpuid]}

    #If target speed is 0 then just leave it alone.
    if [ "$target_speed" -eq 0 ] ; then
        echo "GPU$gpuid memory offset default"
        return 
    fi

    #Check it's within the range.. this will also fail if it's not an int
    if [ "$target_speed" -ge "$MIN_MEM_SPEED" -a "$target_speed" -le "$MAX_MEM_SPEED" ] ; then
        echo -n "GPU$gpuid memory offset $target_speed"
        #We are good to go with the overclock!
        mem_cmd="nvidia-settings -c $DISPLAY -a [gpu:$gpuid]/GPUMemoryTransferRateOffset=$target_speed"
        echo "  $mem_cmd"
    else
        echo "Passed an invalid GPU memory offset.."
        echo "Passed : $target_speed, min is $MIN_MEM_SPEED and max is $MAX_MEM_SPEED"
        exit 5
    fi
}

###Functon which sets the power limit using the configuration file sourced
#$1 - gpuid to set power limit for
function setup_power_limit {
    gpuid=$1
    power_limit=${GPUPowerLimit[$gpuid]}
    echo "Setting up power limit for GPU$gpuid"
    #Check power limit is within valid values
    if [ "$power_limit" -ge "$MIN_POWER_LIMIT" -a "$power_limit" -le "$MAX_POWER_LIMIT" ] ; then
        #We are good to set the power limit
        pl_cmd="nvidia-smi -i $gpuid -pl $power_limit"
        echo -n "GPU$gpuid power limit $power_limit"
        echo "  $pl_cmd"
    else
        echo "Passed an invalid power limit"
        echo "Passed : $power_limit, min is $MIN_POWER_LIMIT and max is $MAX_POWER_LIMIT"
        exit 5
    fi
}

###Function which sets persistence mode to 1
#$1 - gpuid to set persistence for
function setup_persistence {
    gpuid=$1
    echo -n "GPU${gpuid} persistence"
    per_cmd="nvidia-smi -i $gpuid -pm ENABLED"
    echo "  $per_cmd"
}

###Function which sets the core clock offset using the configuration file sourced
#$1 - gpuid to set the core clock freq for
function setup_core_clock {
    gpuid=$1
    #Check it's within limits
    core_clock=${GPUGraphicsClockOffset[$gpuid]}

    if [ "$core_clock" -ge "$MIN_CORE_CLOCK" -a "$core_clock" -le "$MAX_CORE_CLOCK" ] ; then
        core_cmd="nvidia-settings -c $DISPLAY -a [gpu:$gpuid]/GPUGraphicsClockOffset=$core_clock"
        echo -n "GPU${gpuid} core offset $core_clock"
        echo "  $core_cmd"
    else
        echo "Passed an invalid GPUGraphicsClockOffset"
        echo "Passed : $core_clock, min is $MIN_CORE_CLOCK and max is $MAX_CORE_CLOCK"
        exit 5
    fi
}

###Function which sets PowerMizer using the configuration file sourced
#(this does fuck all on 1060's it seems)
#$1 - gpuid to set the PowerMizer mode for
function setup_power_mizer {
    gpuid=$1
    power_mizer=${GPUPowerMizer[$gpuid]}
    #Check it's within our limits
    if [ "$power_mizer" -ge "$MIN_POWER_MIZER" -a "$power_mizer" -le "$MAX_POWER_LIMIT" ] ; then
        pm_cmd="nvidia-settings -c $DISPLAY -a [gpu:$gpuid]/PowerMizerMode=$power_mizer"
        echo -n "GPU$gpuid power mizer $power_mizer"
        echo "  $pm_cmd"
    else
        echo "Passed an invalid PowerMizerMode"
        echo "Passed : $power_mizer, min is $MIN_POWER_MIZER and max is $MAX_POWER_MIZER"
        exit 5
    fi
}

#Main overclocking loop
for (( gpu=0;gpu<"$CARDS";gpu++ )) ; do
    setup_persistence $gpu
    [ "$SET_PM" == "YUP" ] && setup_power_mizer $gpu && echo " Done."
    [ "$SET_PL" == "YUP" ] && setup_power_limit $gpu && echo " Done."
    #actual overclocking
    [ "$SET_FAN" == "YUP" ] && setup_fans $gpu && echo " Done."
    [ "$SET_MEM" == "YUP" ] && setup_mem_clock $gpu echo " Done."
    [ "$SET_CORE" == "YUP" ] && setup_core_clock $gpu echo " Done."
    #TODO: find out how to do voltage
done
