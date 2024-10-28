#!/bin/bash
#Copyright (C) 2022 Intel Corporation
#SPDX-License-Identifier: BSD-3-Clause
# uses $SDE_BUILD_KIT/pinkit/sde-example/example/pcregions_control.cpp
# First build 32-bit and 64-bit versions of the relevant tool and copy
# them to the SDE_BUILD_KIT tools directories where 'sde' expects them
# Build instructions:
# cd $SDE_BUILD_KIT/pinkit/sde-example/example
#  make TARGET=ia32 clean;  make TARGET=ia32
#  make TARGET=intel64 clean;  make TARGET=intel64
#  cp obj-ia32/pcregions_control.so $SDE_BUILD_KIT/ia32
#  cp obj-intel64/pcregions_control.so $SDE_BUILD_KIT/intel64
export OMP_NUM_THREADS=0
SLICESIZE=80000000
WARMUP_FACTOR=0
MAXK=5
PROGRAM=dotproduct-st
INPUT=1
COMMAND="./dotproduct-st"

PCCOUNT="--pccount_regions"
WARMUP="--warmup_factor $WARMUP_FACTOR" 
#GLOBAL="--global_regions"
GLOBAL=""
PAR=3 # how many regions to process in parallel. Should have PAR*OMP_NUM_THREADS
  # cores available on the test machine


if [ -z $SDE_BUILD_KIT ];
then
  echo "Set SDE_BUILD_KIT to point to the latest (internal)SDE kit"
  exit 1
fi

if [ ! -e $SDE_BUILD_KIT/pinplay-scripts ];
then
  echo "$SDE_BUILD_KIT/pinplay-scripts does not exist"
  cp -r ../pinplay-scripts $SDE_BUILD_KIT
fi

if [ ! -e $SDE_BUILD_KIT/pinplay-scripts/PinPointsHome/Linux/bin/simpoint ];
then
  echo "$SDE_BUILD_KIT/pinplay-scripts//PinPointsHome/Linux/bin/simpoint does not exist"
  echo " Attempting to build it ..."
  pushd $SDE_BUILD_KIT/pinplay-scripts//PinPointsHome/Linux/bin/
  make clean; make
  popd
  if [ ! -e $SDE_BUILD_KIT/pinplay-scripts/PinPointsHome/Linux/bin/simpoint ];
  then
    echo "$SDE_BUILD_KIT/pinplay-scripts//PinPointsHome/Linux/bin/simpoint does not exist"
    echo "See $SDE_BUILD_KIT/pinplay-scripts/README.simpoint"
    exit 1
  fi
fi

if [ ! -e $SDE_BUILD_KIT/intel64/pcregions_control.so ];
then
  echo " $SDE_BUILD_KIT/intel64/pcregions_control.so is missing"
  echo "   See build instructions above"
  exit 1
fi

if [ ! -e $SDE_BUILD_KIT/ia32/pcregions_control.so ];
then
  echo " $SDE_BUILD_KIT/ia32/pcregions_control.so is missing"
  echo "   See build instructions above"
  exit 1
fi

sch="active"
if [ $# -eq 1 ];
then
 sch=$1
fi

if [ ! -e $sch.env.sh ];
then
  echo "./$sch.env.sh does not exist; using ./active.env.sh"
  sch="active"
fi
echo "source ./$sch.env.sh"
source ./$sch.env.sh

#Whole Program Logging and replay using the default sde tool
# We are recording starting at 'main'
$SDE_BUILD_KIT/pinplay-scripts/sde_pinpoints.py $GLOBAL $PCCOUNT --program_name=$PROGRAM --input_name=$INPUT --command="$COMMAND" --delete --mode st --log_options="-start_address main -log:fat -log:mp_mode 0 -log:mp_atomic 0" --replay_options="-replay:strace" -l -r 

#Profiling using regular profiler from the default sde tool
$SDE_BUILD_KIT/pinplay-scripts/sde_pinpoints.py $GLOBAL $PCCOUNT --program_name=$PROGRAM --input_name=$INPUT --command="$COMMAND" --mode st -S $SLICESIZE -b 

#Simpoint
$SDE_BUILD_KIT/pinplay-scripts/sde_pinpoints.py $GLOBAL $PCCOUNT  --program_name=$PROGRAM --input_name=$INPUT --command="$COMMAND" $PCCOUNT -S $SLICESIZE $WARMUP --maxk=$MAXK --append_status -s 

#Region pinball generation and replay
# This does not work because currently the tool pcregions_control.so is NOT 
# naming pcregions regions as expected by the sde_pinpoints.py script
#$SDE_BUILD_KIT/pinplay-scripts/sde_pinpoints.py $GLOBAL $PCCOUNT  --pintool="pcregions_control.so"  --program_name=$PROGRAM --input_name=$INPUT --command="$COMMAND" $WARMUP -S $SLICESIZE --mode mt --coop_pinball --append_status --log_options="-log:fat -log:region_id -controller_log -controller_olog sde.bbpoint.controller.txt" --replay_options="-replay:strace" -p -R 
# Create per-region CSV files
wpb=`ls whole_program.$INPUT/*.address | sed '/.address/s///'`
wpbname=`basename $wpb`
ddir="$wpbname.Data"
pdir="$wpbname.pp"
csvfile=`ls $ddir/*.pinpoints.csv`
$SDE_BUILD_KIT/pinplay-scripts/split.pc-csvfile.py --csv_file $csvfile
echo "SDE_BUILD_KIT  = $SDE_BUILD_KIT" > Makefile.regions
# Using sde64 below as 'make' and 32-bit 'sde' binary do not work well
for rcsv in `ls $ddir/*.CSV`
do
  rid=`echo $rcsv | awk -F "." '{print $(NF-1)}'`
  rpbname=$wpbname"_"$rid
  #echo $rcsv $rid $rpbname
  rstr="t"$rid
  echo $rstr":" >> Makefile.regions
  echo "	\${SDE_BUILD_KIT}/sde64 -p -xyzzy -p -reserve_memory -p $wpb.address   -t pcregions_control.so -replay -xyzzy  -replay:deadlock_timeout 0  -replay:basename $wpb -replay:playout 0  -replay:strace  -dcfg -dcfg:read_dcfg 1 -log:fat -log -xyzzy -pcregions:in $rcsv -pcregions:merge_warmup -log:basename $pdir/$rpbname -log:compressed bzip2  -log:mt 0 -- \${SDE_BUILD_KIT}/intel64/nullapp" >> Makefile.regions
  astr=$astr" "$rstr
done
echo "all:" $astr >> Makefile.regions
echo "Makefile.regions created"
echo "Running with -j $PAR"
make -j $PAR -f Makefile.regions all
for rpb in `ls $pdir/*.address`
do
  rpbname=`echo $rpb | sed '/.address/s///'`
  echo "replaying $rpbname"
  $SDE_BUILD_KIT/pinplay-scripts/replay $rpbname
done
