#!/bin/bash
set -eo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

usage() {
  cat <<EOF
This sript takes a csv file with acceleration measurements and a csv
file with location messurements from the Android app "phyphox" and
generates a gpx file out of it in which the elevation values are actually
the z acceleration values.

Why is this information usefull? It can be used with a standard gpx viewer
to see how the bike lane quality is and where problematic locations are
"hidden" on the bike path.

Dependencies: GMT's "sample1d", gpsbable, basic linux commands
              python for finding largest values, pandas python package

-h, --help            Print this help and exit
-v, --verbose         Print script debug info
-o, --output          The output file name can be overridden, default is "xyz_data.gpx"
-l, --locations       This is the input file of the phyphox experiment, default is "Location.csv"
-a, --accelerations   This is the acceleration measurement file from phyphox
                      where the gravitational acceleration is not taken into account, default "Accelerometer.csv"
                      This file does not need to be existing if the file "Linear Acceleration.csv" is available.
-m, --max             The number of gps positions this script should find where the acceleration in z direction is exceptional, default 5
    --onlymax         Only create a gpx file pointing to positions with maximum z-acceleration
-t, --window          The time window in seconds in which a no other value with high z accelerations will be searched, default 2
    --test            Apply an automatic regression test to check if all dependencies work as expected
EOF
  exit
}

# Use colors like this:
# msg "${RED}Read parameters:${NOFORMAT}"
setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg="${RED}${1}${NOFORMAT}"
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

check_dependencies() {
  which GMT      >&2 > /dev/null || die "GMT binary not found"
  which gpsbabel >&2 > /dev/null || die "gpsbabel binary not found"
}

setup_test_vars()
{
    ACCSTESTFILE=$(mktemp /tmp/XXXXXX --dry-run)
    COORDSTESTFILE=$(mktemp /tmp/XXXXXX --dry-run)
}

parse_params() {
  # default values of variables set from params
  OUTPUT_ARG="xyz_data.gpx"
  LOCATIONFILE="Location.csv"
  ACCELEROMETERFILE="Accelerometer.csv"
  ACCELEROMETERFILE_ALTERNATE="Linear Acceleration.csv"
  BAD_STREET_POSITIONS_ARG="5"
  TIME_WINDOW_ARG="2"
  UNRESAMPLED=NO
  TEST=NO

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -o | --output)
      OUTPUT_ARG="${2-}"
      shift
      ;;
    -l | --locations)
      LOCATIONFILE_ARG="${2-}"
      shift
      ;;
    -a | --accelerations)
      ACCELEROMETERFILE_ARG="${2-}"
      shift
      ;;
    -m | --max)
      BAD_STREET_POSITIONS_ARG="${2-}"
      shift
      ;;
    -t | --window)
      TIME_WINDOW_ARG="${2-}"
      shift
      ;;
    --onlymax)
      UNRESAMPLED=YES ;;
    --test)
      TEST=YES ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}


setup_input_vars()
{
    # Detect which acceleration file is available, set GVALUE accordingly
    GVALUE="0.0"
    if [[ $TEST == "NO" ]] && [[ "${ACCELEROMETERFILE_ARG}" == "" ]] && [[ ! -f "$ACCELEROMETERFILE" ]]; then
        if [ ! -f "$ACCELEROMETERFILE_ALTERNATE" ]; then
            echo "Acceleration input file not found"
            exit 1
        else
            ACCELEROMETERFILE="$ACCELEROMETERFILE_ALTERNATE"
            GVALUE="9.81"
        fi
    fi

    # Assign values of script arguments
    if [ "${OUTPUT_ARG}" != "" ]; then
        OUTPUTFILENAME="${OUTPUT_ARG}"
    fi
    if [ "${LOCATIONFILE_ARG}" != "" ]; then
        LOCATIONFILE="${LOCATIONFILE_ARG}"
    fi
    if [ "${ACCELEROMETERFILE_ARG}" != "" ]; then
        ACCELEROMETERFILE="${ACCELEROMETERFILE_ARG}"
    fi
    if [ "${BAD_STREET_POSITIONS_ARG}" != "" ]; then
        BAD_STREET_POSITIONS="${BAD_STREET_POSITIONS_ARG}"
    fi
    if [ "${TIME_WINDOW_ARG}" != "" ]; then
        TIME_WINDOW="${TIME_WINDOW_ARG}"
    fi
}

################################################################################
############################## CLEANUP SECTION #################################
################################################################################

cleanup_tests()
{
    msg "Cleanup test files ..."

    rm $ACCSTESTFILE
    rm $COORDSTESTFILE

    msg "Done."
}

cleanup() {
    trap - SIGINT SIGTERM ERR EXIT

    if [ "$TEST" == "YES" ]; then
    	cleanup_tests
    fi
}

################################################################################
############################### TEST SECTION ###################################
################################################################################

output_actual_vs_expected()
{
    msg "Actual value: ${1}, Expected: ${2}"
    echo
}

write_files_test()
{
    lines=$(wc -l $ACCSTESTFILE | cut -d " " -f 1)
    if [[ $lines -ne 4 ]]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "Lines of accelerations file ${ACCSTESTFILE}:"
        output_actual_vs_expected $lines 4
        return 1
    fi

    lines=$(wc -l $COORDSTESTFILE | cut -d " " -f 1)
    if [[ $lines -ne 3 ]]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "Lines of coordinations file ${COORDSTESTFILE}:"
        output_actual_vs_expected $lines 3
        return 1
    fi

    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

export_times_and_zaccs_in_file_test()
{
    ACCLS=$(export_times_and_zaccs_in_file "$ACCSTESTFILE")
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0.000000000E0,1.000000000E-1
5.000000000E-1,2.000000000E-1
1.000000000E0,3.000000000E-1
EOF
    set +e
    cmp --silent $EXPECTED_FILE $ACCLS
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $ACCLS
        rm $ACCLS
        rm $EXPECTED_FILE
        return 1
    fi
    rm $ACCLS
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

export_time_lat_long_speed_test()
{
    COORDS=$(export_time_lat_long_speed "$COORDSTESTFILE")
    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0.000000000E0,4.000000000E1,5.000000000E0,1.000000000E0
1.000000000E0,5.000000000E1,6.000000000E0,2.000000000E0
EOF
    set +e
    cmp --silent $EXPECTED_FILE $COORDS
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $COORDS
        rm $COORDS
        rm $EXPECTED_FILE
        return 1
    fi
    rm $COORDS
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

generate_resampled_coords_file_test(){
    COORDSFILETMP=$(export_time_lat_long_speed "$COORDSTESTFILE")
    ZACCLSFILETMP=$(export_times_and_zaccs_in_file "$ACCSTESTFILE")

    RESAMPLED_COORDS_FILE=$(generate_resampled_coords_file $COORDSFILETMP $ZACCLSFILETMP)

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0	40	5	1
0.5	45	5.5	1.5
1	50	6	2
EOF
    set +e
    cmp --silent $EXPECTED_FILE $RESAMPLED_COORDS_FILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $RESAMPLED_COORDS_FILE
        rm $RESAMPLED_COORDS_FILE
        rm $EXPECTED_FILE
        return 1
    fi
    rm $RESAMPLED_COORDS_FILE
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

merge_coords_and_zacc_file_test()
{
    COORDSFILETMP=$(export_time_lat_long_speed "$COORDSTESTFILE")
    ZACCLSFILETMP=$(export_times_and_zaccs_in_file "$ACCSTESTFILE")
    RESAMPLED_COORDS_FILE=$(generate_resampled_coords_file $COORDSFILETMP $ZACCLSFILETMP)
    MERGEDTESTFILE=$(merge_coords_and_zacc_file $ZACCLSFILETMP $RESAMPLED_COORDS_FILE)

    rm $COORDSFILETMP $ZACCLSFILETMP $RESAMPLED_COORDS_FILE

    EXPECTED_FILE=$(mktemp /tmp/XXXXXX)
    cat <<EOF > $EXPECTED_FILE
0,40,5,1,1.000000000E-1
0.5,45,5.5,1.5,2.000000000E-1
1,50,6,2,3.000000000E-1
EOF
    set +e
    cmp --silent $EXPECTED_FILE $MERGEDTESTFILE
    retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        msg "${FUNCNAME[0]}: ${RED}failed${NOFORMAT}"
        msg "expected:"
        cat $EXPECTED_FILE
        msg "got:"
        cat $MERGEDTESTFILE
        rm $MERGEDTESTFILE
        rm $EXPECTED_FILE
        return 1
    fi
    rm $MERGEDTESTFILE
    rm $EXPECTED_FILE
    msg "${FUNCNAME[0]}: ${GREEN}passed${NOFORMAT}"
    return 0
}

do_regression_tests()
{
    cat <<EOF > $ACCSTESTFILE
"Time (s)","Linear Acceleration x (m/s^2)","Linear Acceleration y (m/s^2)","Linear Acceleration z (m/s^2)"
0.000000000E0,1.000000000E-1,2.000000000E-1,1.000000000E-1
5.000000000E-1,1.000000000E-1,2.000000000E-1,2.000000000E-1
1.000000000E0,1.000000000E-1,2.000000000E-1,3.000000000E-1
EOF

    cat <<EOF > $COORDSTESTFILE
"Time (s)","Latitude (°)","Longitude (°)","Height (m)","Velocity (m/s)","Direction (°)","Horizontal Accuracy (m)","Vertical Accuracy (m)"
0.000000000E0,4.000000000E1,5.000000000E0,1.200000000E2,1.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
1.000000000E0,5.000000000E1,6.000000000E0,1.200000000E2,2.000000000E0,0.000000000E0,1.000000000E1,1.000000000E1
EOF

    write_files_test
    export_times_and_zaccs_in_file_test
    export_time_lat_long_speed_test
    generate_resampled_coords_file_test
    merge_coords_and_zacc_file_test
    echo
}

################################################################################
################### BELOW THIS LINE THE ACTUAL LOGIC HAPPENS ###################
################################################################################

# Just leave the time and acceleration in z-direction
export_times_and_zaccs_in_file()
{
    TMPFILE=$(mktemp /tmp/XXXXXX)
    cut "$1" -d, -f1,4 > $TMPFILE
    sed -i '1d;' $TMPFILE
    echo "$TMPFILE"
}

# Leave time, latitude, longitue, speed
export_time_lat_long_speed ()
{
    TMPFILE=$(mktemp /tmp/XXXXXX)
    cut "$1" -d, -f1-3,5 > $TMPFILE
    sed -i '1d;' $TMPFILE
    echo "$TMPFILE"
}

generate_resampled_coords_file(){
    TMPFILE=$(mktemp /tmp/XXXXXX)
    GMT sample1d $1 -N$2 > $TMPFILE
    echo "$TMPFILE"
}

merge_coords_and_zacc_file()
{
    # Remove timestamps from acceleration file
    sed -i 's/^[^,]*,//g' $1
    # Convert tabs to comma in coordination file
    sed -i 's/\t/,/g;' $2

    TMPFILE=$(mktemp /tmp/XXXXXX)
    paste -d, $2 $1 > $TMPFILE
    echo "$TMPFILE"
}

execute()
{
    ZACCLSFILE=$(export_times_and_zaccs_in_file "$ACCELEROMETERFILE")
    COORDSFILE=$(export_time_lat_long_speed "$LOCATIONFILE")
    COORDS_RESAMPLED_FILE=$(generate_resampled_coords_file $COORDSFILE $ZACCLSFILE)
    COORDSANDACCSFILE=$(merge_coords_and_zacc_file $ZACCLSFILE $COORDS_RESAMPLED_FILE)

    rm $ZACCLSFILE $COORDS_RESAMPLED

    # Remove lines which start with a comma after merging
    sed -i '/^,/d' $COORDSANDACCSFILE

    # Include header - This file will be used later to analyze the data with a Python script
    COORDSANDACCSFILEWITHHEADER=$(mktemp /tmp/XXXXXX)
    sed '1i time, y, x, speed, z' $COORDSANDACCSFILE > $COORDSANDACCSFILEWITHHEADER

    # This file will be used to export the final results to.
    # We don't need time information in it.
    MERGED_WO_TIME=$(mktemp /tmp/XXXXXX)
    cut -d, -f2,3,4,5 $COORDSANDACCSFILE > $MERGED_WO_TIME
    sed -i '1i y, x, speed, z' $MERGED_WO_TIME # Include header
    rm $COORDSANDACCSFILE

    # Create the gpx file with acceleration data
    MERGED_WO_TIME_GPX=$(mktemp /tmp/XXXXXX)
    gpsbabel -t -i unicsv -f $MERGED_WO_TIME -o gpx -F $MERGED_WO_TIME_GPX
    rm $MERGED_WO_TIME

    # Create the unresampled gpx file (from the original data)
    if [ $UNRESAMPLED == "YES" ]; then
        COORDS_WO_TIME=$(mktemp /tmp/XXXXXX)
        cut -d, -f2,3 $COORDSFILE > $COORDS_WO_TIME
        COORDS_WO_TIME_CONVERTED=$(mktemp /tmp/XXXXXX)
        OLDIFS=$IFS
        IFS=','
        while read LAT LON
        do
            LAT_CONV=$(echo $LAT | awk '{printf("%3.9f",$0);}')
            LON_CONV=$(echo $LON | awk '{printf("%3.9f",$0);}')
            echo "$LAT_CONV, $LON_CONV" >> $COORDS_WO_TIME_CONVERTED
        done < $COORDS_WO_TIME
        IFS=$OLDIFS

        sed -i '1i lat, long' $COORDS_WO_TIME_CONVERTED # Include header
        COORDS_WO_TIME_CONVERTED_GPX=$(mktemp /tmp/XXXXXX)
        gpsbabel -t -i unicsv -f $COORDS_WO_TIME_CONVERTED -o gpx -F $COORDS_WO_TIME_CONVERTED_GPX
        rm $COORDS_WO_TIME
        rm $COORDS_WO_TIME_CONVERTED
    fi

    rm $COORDSFILE

    # Get the coordinates with the highest z values in a seperate gpx file
    HIGH_Z_COORDS=$(mktemp /tmp/XXXXXX)

    # Get the path of this script
    SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

    # Find the gps coordinates where the highest z acceleration values happened
    python "$SCRIPTPATH"/acceleration_selection.py -i $COORDSANDACCSFILEWITHHEADER -b $BAD_STREET_POSITIONS -t $TIME_WINDOW -o $HIGH_Z_COORDS -g $GVALUE

    rm $COORDSANDACCSFILEWITHHEADER

    TIME_SORTED_Z_COORDS=$(mktemp /tmp/XXXXXX)
    cat $HIGH_Z_COORDS | (read -r; printf "%s\n" "$REPLY"; sort -g) | cut -d, -f2,3,4,5 > $TIME_SORTED_Z_COORDS

    TIME_SORTED_Z_COORDS_GPX=$(mktemp /tmp/XXXXXX)
    gpsbabel -i unicsv -f $TIME_SORTED_Z_COORDS -o gpx -F $TIME_SORTED_Z_COORDS_GPX
    rm $HIGH_Z_COORDS
    rm $TIME_SORTED_Z_COORDS

    # Merge the last gpx into the first one and create a seperate output file
    gpsbabel -i gpx -f $TIME_SORTED_Z_COORDS_GPX -i gpx -f $MERGED_WO_TIME_GPX -o gpx -F $OUTPUTFILENAME
    rm $MERGED_WO_TIME_GPX

    if [ $UNRESAMPLED == "YES" ]; then
        gpsbabel -i gpx -f $TIME_SORTED_Z_COORDS_GPX -i gpx -f $COORDS_WO_TIME_CONVERTED_GPX -o gpx -F $(echo $OUTPUTFILENAME | sed 's/\(^.*\)\.gpx/\1_unresampled.gpx/g')
        rm $COORDS_WO_TIME_CONVERTED_GPX
    fi

    rm $TIME_SORTED_Z_COORDS_GPX
}

main()
{
    # Some setup
    setup_colors
    check_dependencies
    parse_params "$@"
    setup_input_vars
    setup_test_vars

    # Execute tests if needed
    if [ $TEST == "YES" ]; then
        do_regression_tests
        exit 0
    fi

    # And go
    execute
}

main "$@"
