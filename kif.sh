#!/bin/bash

# Kerning Input File compiler for TrueType AAT
# Copyright 2013 Grzegorz Rolek


usage="usage: $(basename $0) [-x] <post.xml> <kern.kif>"

# Prints a message to stderr and exits.
err () {
	echo >&2 $0: $1
	exit ${2-1}
}

# Parse and reset the arguments.
args=$(getopt x $*)
test $? -ne 0 &&
	err "$usage" 2
set -- $args

tag='kern'; v=1 # Table version, 'kern' by default
for i
do
	case "$i" in
		-x) tag='kerx'; v=2; shift;;
		--) shift; break;;
	esac
done

# Make sure both file arguments are given.
test $# != 2 &&
	err "$usage" 2

post=$1 # Path to the 'post' table dump

# Find the line offset to the first glyph name record in the 'post' dump.
postoff=$(grep -n '\.notdef' $post | cut -d : -f 1)
test $postoff ||
	err "fatal: required glyph .notdef missing"

# Parse the 'post' table dump for an array of glyphs names.
glnames=($(sed -n 's/<PostScriptName ..* NameString=\"\(..*\)\".*>/\1/p' <$post))

# Fills $index with index of a token within the list following the token.
indexof () {
	index=0
	token=$1
	shift
	for item
	do
		test $token = $item && return
		let index++
	done
	index=-1
}


let tabhead=4+2*2*$v # Subtable header size
let cloff=5*2*$v # Class table offset (length of a state table header)
let clsize=1*$v # Size of the mapping entry
let trsize=1*$v # Transition size
let etsize=2+2*$v # Full entry size in the entry table
let vlsize=2 # Value size

printf "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>\n"
printf "<genericSFNTTable tag=\"%s\">\n" $tag

# Print the table header before reading actual subtables.
ntables=$(grep -c '^Type[ 	]' $2)
off=0 # current offset into the table

printf "\t<dataline offset=\"%08X\" hex=\"%04X%04X\"/> <!-- %s -->\n" \
	$off $v 0 "Table version" && let off+=4

printf "\t<dataline offset=\"%08X\" hex=\"%08X\"/> <!-- %s -->\n" \
	$off $ntables "No. of subtables" && let off+=4

{

read

# Skip blank lines and line comments in front of the input file.
until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
do read
done

# Read the file subtable by subtable to the end of file.
while test "$REPLY" -a -z "${REPLY##Type[ 	]*}"
do

	vertical='no'
	crossstream='no'
	unset tabfmt # Subtable format
	classes=() # GID-indexed array of classes
	clnames=(EOT OOB DEL EOL) # Class names
	unset glstart # First glyph assigned to a class
	unset glend # Last glyph assigned to a class
	clsegments=() # Class lookup segments (extended table only)
	states=() # State records
	stnames=() # State names
	gotos=() # Next states
	gtnames=() # Names of the next states
	flpush=() # Flags for the push action
	fladvance=() # Flags for the advance action
	actions=() # Kern value lists to apply
	actnames=() # Names of kern value lists to apply
	values=() # Kerning values
	vlnames=() # Names of the kern value lists
	vlindices=() # Indexes of values beginning the lists

	# Parse the input line, comments excluded.
	line=(${REPLY%%[ 	]\/\/*})
	test $line != "Type" &&
		err "fatal: kerning type expected"
	case ${line[@]:1} in
		Contextual) tabfmt=1;;
		*) err "fatal: unknown kerning type: ${line[@]:1}";;
	esac

	read

	until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
	do read
	done

	line=(${REPLY%%[ 	]\/\/*})
	test $line != "Orientation" &&
		err "fatal: kerning orientation expected"
	case ${line[@]:1} in
		V) vertical='yes';;
		H) ;;
		*) err "fatal: bad orientation flag: ${line[@]:1}";;
	esac

	read

	until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
	do read
	done

	line=(${REPLY%%[ 	]\/\/*})
	if test $line = "Cross-stream"
	then
		case ${line[@]:1} in
			yes) crossstream='yes';;
			no) ;;
			*) err "fatal: bad cross-stream flag: ${line[@]:1}";;
		esac

		read

		until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
		do read
		done
	fi

	unset nclasses

	# Read classes until a state table header (indented line).
	until test -z "${REPLY##[ 	]*}"
	do
		line=(${REPLY%%[ 	]\/\/*})
		if test $line != '+'
		then
			nclasses=${#clnames[@]}
			clnames=(${clnames[@]} $line)
		fi

		for glyph in ${line[@]:1}
		do
			index=$(grep -n "\"$glyph\"" $post | cut -d : -f 1)
			test $index ||
				err "fatal: glyph not found: $glyph"
			let index-=$postoff
			classes[$index]=$nclasses
			test $index -lt ${glstart=$index} && glstart=$index
			test $index -gt ${glend=$index} && glend=$index
		done

		read

		# Skip blanks and comments inbetween.
		until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
		do read
		done
	done

	# Update the number of classes for later use.
	let nclasses++

	# Set an Out-of-Bounds class on glyphs inbetween the specified ones.
	for i in $(seq $glstart $glend)
	do test "${classes[$i]}" || classes[$i]=1
	done

	# Check if the class list and state table header match.
	line=(${REPLY%%[ 	]\/\/*})
	test "${clnames[*]}" != "${line[*]}" &&
		err "fatal: classes and state header don't match"

	read

	# Skip blanks directly beneath the header.
	until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
	do read
	done

	# Read the state table until a blank or indented line.
	until test -z "${REPLY//[ 	]/}" -o -z "${REPLY##[ 	]*}"
	do
		line=(${REPLY%%[ 	]\/\/*})
		stnames=(${stnames[@]} $line)

		# Make the entry numbers zero-based.
		state=()
		for entry in ${line[@]:1}
		do
			let entry--
			state=(${state[@]} $entry)
		done

		test "${#state[@]}" -ne "$nclasses" &&
			err "fatal: wrong entry count in state: $line"
		states[${#states[@]}]="${state[@]}"

		read

		# Skip line comments, but break on a blank line.
		while test "${REPLY//[ 	]/}" -a -z "${REPLY##\/\/*}"
		do read
		done
	done

	# Skip any more blanks if necessary.
	until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
	do read
	done

	# Check if the entry table header is as expected.
	line=(${REPLY%%[ 	]\/\/*})
	test "${line[*]}" != "GoTo Push? Advance? KernValues" &&
		err "fatal: malformed entry table header"

	read

	# Skip blanks beneath the header.
	until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
	do read
	done

	# Read entries until a blank line, or an indent (the Font Tools way).
	until test -z "${REPLY//[ 	]/}" -o -z "${REPLY##[ 	]*}"
	do
		line=(${REPLY%%[ 	]\/\/*})
		let entry=${#gotos[@]}+1
		test $line -eq $entry ||
			err "fatal: wrong number for entry listed as $entry"

		stname=${line[@]:1:1}
		indexof $stname ${stnames[@]}
		test $index -eq -1 &&
			err "fatal: state not found: $stname"
		gotos=(${gotos[@]} $index)
		gtnames=(${gtnames[@]} $stname)

		flpush=(${flpush[@]} ${line[@]:2:1})
		fladvance=(${fladvance[@]} ${line[@]:3:1})
		actnames=(${actnames[@]} ${line[@]:4:1})

		read

		# Skip comments, but break on a blank.
		while test "${REPLY//[ 	]/}" -a -z "${REPLY##\/\/*}"
		do read
		done
	done

	until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
	do read
	done

	# Read values until the end of file or a next subtable header.
	until test -z "$REPLY" -o -z "${REPLY##Type[ 	]*}"
	do
		line=(${REPLY%%[ 	]\/\/*})
		vlnames=(${vlnames[@]} $line)
		vlindices=(${vlindices[@]} ${#values[@]})

		read || break

		# Skip blanks beneath the kern list name.
		until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
		do read || break 2
		done

		# Read values in all the indented lines beneath the name.
		while test -z "${REPLY##[ 	]*}"
		do
			line=(${REPLY%%[ 	]\/\/*})

			# Fail on a reset value in a non-cross-stream table.
			! test $crossstream = 'yes' &&
				test -z "${REPLY##*Reset*}" &&
				err "fatal: kern reset in a non-cross-stream table"

			values=(${values[@]} ${line[@]})

			read || break 2

			# Skip blanks between the values, if any.
			until test "${REPLY//[ 	]/}" -a "${REPLY##\/\/*}"
			do read || break 3
			done
		done
	done

	# Now with the values parsed match their indices to actions.
	for i in ${!actnames[@]}
	do
		vlname=${actnames[$i]}
		action=-1

		if test $vlname != 'none'
		then
			indexof $vlname ${vlnames[@]}
			test $index -eq -1 &&
				err "fatal: kern values not found: $vlname"
			action=$index
		fi

		actions[$i]=$action
	done

	# Pre-compute the end-of-list marker count prior to each action.
	if test $tag = 'kerx'
	then
		eolmarks=() # Marker count, action-indexed
		previndex=0
		nmarks=0
		for i in ${!vlindices[@]}
		do
			currindex=${vlindices[$i]}

			# Increase the count for non-empty actions only.
			test $currindex -gt $previndex &&
				let nmarks++

			eolmarks[$i]=$nmarks
			previndex=$currindex
		done
	fi

	if test $tag = 'kerx'
	then
		# Filter out glyph segments for the class lookups.
		i=$glstart
		while test $i -le $glend
		do
			class=${classes[$i]}

			# Skip the out-of-bounds class.
			if test $class -eq 1
			then
				let i++
				continue
			fi

			first=$i

			# Skip to the last subsequent glyph with same class.
			until test $i -eq $glend ||
				test ${classes[(( i+1 ))]} -ne $class
			do let i++
			done

			clsegment=($i $first $class)
			clsegments[${#clsegments[@]}]=${clsegment[@]}
			let i++
		done

		let clhead=6*2 # Size of a binsearch lookup table header
		let mapsize=2*2+$clsize # Mapping size
		let nmappings=${#clsegments[@]}+1 # No. of mappings
	else
		let clhead=2*2 # Size of a trimmed array header
		let mapsize=$clsize # Mapping size
		let nmappings=$glend-$glstart+1 # No. of mappings
	fi

	let cllen=$clhead+$nmappings*$mapsize # Class table length
	let clpad=$cllen/$v%2*$v # Padding
	let stoff=$cloff+$cllen+$clpad # State table offset
	let stlen=${#states[@]}*$nclasses*$trsize # State table length
	let stpad=$stlen/$v%2*$v # Padding
	let etoff=$stoff+$stlen+$stpad # Entry table offset
	let etlen=${#gotos[@]}*$etsize # Entry table length
	let etpad=$etlen/$v%2*$v # Padding
	let vloff=$etoff+$etlen+$etpad # Kern values offset
	let vllen=${#values[@]}*$vlsize # Values length
	test $tag = 'kerx' &&
		let vllen+=\($nmarks+1\)*$vlsize # the end-of-list markers
	let vlpad=$vllen/$v%2*$v # Padding
	let tablen=$tabhead+$vloff+$vllen+$vlpad # Subtable length

	# Start printing the subtable with headers and the class lookups.
	printf "\n\t<!-- Subtable No. %d -->\n" $(( ++tabno ))

	printf "\n\t<dataline offset=\"%08X\" hex=\"%08X\"/> <!-- %s -->\n" \
		$off $tablen "Subtable length" && let off+=4

	flcover=0
	test $vertical = 'yes' && let flcover+=16#80
	test $crossstream = 'yes' && let flcover+=16#40

	# Make the coverage field 2 bytes longer for the extended table.
	test $tag = 'kerx' && (( flcover <<= 16 ))

	printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/> <!-- %s -->\n" \
		$off $(( 4*v - 2 )) $flcover "Coverage" \
		$(( off += 2*v - 1 )) 2 $tabfmt "Format" && let off+=1

	printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/> <!-- %s -->\n" \
		$off $(( 4*v )) 0 "Variation tuple index" && let off+=2*$v

	printf "\n"
	printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/> <!-- %s -->\n" \
		$off $(( 4*v )) $nclasses "Class count" \
		$(( off += 2*v )) $(( 4*v )) $cloff "Class lookup offset" \
		$(( off += 2*v )) $(( 4*v )) $stoff "State table offset" \
		$(( off += 2*v )) $(( 4*v )) $etoff "Entry table offset" \
		$(( off += 2*v )) $(( 4*v )) $vloff "Values offset" && let off+=2*$v

	if test $tag = 'kerx'
	then
		# Calculate the binsearch header data.
		nunits=${#clsegments[@]}
		exponent=0
		while test $(( nunits >> exponent )) -gt 1
		do let exponent++
		done
		srange=$(( mapsize * 2**exponent ))
		rshift=$(( mapsize * (nunits - 2**exponent) ))

		printf "\n"
		printf "\t<dataline offset=\"%08X\" hex=\"%04X\"/> <!-- %s -->\n" \
			$off 2 "Lookup format" \
			$(( off += 2 )) $mapsize "Unit size" \
			$(( off += 2 )) $nunits "No. of units" \
			$(( off += 2 )) $srange "Search range" \
			$(( off += 2 )) $exponent "Entry selector" \
			$(( off += 2 )) $rshift "Range shift" && let off+=2

		for i in ${!clsegments[@]}
		do
			s=(${clsegments[i]})
			names="${glnames[${s[0]}]} - ${glnames[${s[1]}]}: ${clnames[${s[2]}]}"
			printf "\t<dataline offset=\"%08X\" hex=\"%04X %04X %04X\"/> <!-- %s -->\n" \
				$off ${clsegments[i]} "$names" && let off+=$mapsize
		done
		printf "\t<dataline offset=\"%08X\" hex=\"%04X %04X %04X\"/> <!-- %s -->\n" \
			$off $(( 16#FFFF )) $(( 16#FFFF )) 0 "Guardian value" && let off+=$mapsize
	else
		printf "\n"
		printf "\t<dataline offset=\"%08X\" hex=\"%04X\"/> <!-- %s -->\n" \
			$off $glstart "First glyph" \
			$(( off += 2 )) $nmappings "Glyph count" && let off+=2

		for i in $(seq $glstart $glend)
		do
			class=${classes[$i]}
			names="${glnames[$i]}: ${clnames[$class]}"
			printf "\t<dataline offset=\"%08X\" hex=\"%02X\"/> <!-- %s -->\n" \
				$off $class "$names" && let off+=$mapsize
		done
	fi

	# Pad the class lookups with zeros for word-alignment if necessary.
	test $clpad -ne 0 &&
		printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/>\n" \
			$off $(( clpad * 2 )) 0 && let off+=$clpad

	# Print at least stubs of class names along the transitions.
	printf "\n\t                            <!-- "
	for clname in ${clnames[@]}
	do printf "%-*.*s " $(( 2*v )) $(( 2*v )) $clname
	done
	printf " -->\n"

	for i in ${!states[@]}
	do
		printf "\t<dataline offset=\"%08X\" hex=\"" $off
		for gtno in ${states[$i]}
		do printf "%0*X " $(( trsize * 2 )) $gtno && let off+=$trsize
		done
		printf "\"/> <!-- %s -->\n" ${stnames[$i]}
	done

	# Pad the state table if necessary.
	test $stpad -ne 0 &&
		printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/>\n" \
			$off $(( stpad * 2 )) 0 && let off+=$stpad

	printf "\n"
	for i in ${!gotos[@]}
	do
		goto=${gotos[$i]}
		action=${actions[$i]}

		# Use byte offsets for the old table.
		test $tag = 'kerx' || let goto=$stoff+$goto*$nclasses

		flact=0 # flags plus action
		test ${flpush[$i]} = 'yes' && let flact+=16#8000
		test ${fladvance[$i]} = 'yes' || let flact+=16#4000
		test $tag = 'kerx' && (( flact <<= 16 ))

		if test $action -ge 0
		then
			vlindex=${vlindices[$action]}

			if test $tag = 'kerx'
			then let flact+=$vlindex+${eolmarks[$action]}
			else let flact+=$vloff+$vlindex*$vlsize
			fi
		else
			test $tag = 'kerx' && let flact+=16#FFFF
		fi

		printf "\t<dataline offset=\"%08X\" hex=\"%04X %0*X\"/> <!-- %02X %s -->\n" \
			$off $goto $(( 4*v )) $flact $i ${gtnames[$i]} && let off+=$etsize
	done

	test $etpad -ne 0 &&
		printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/>\n" \
			$off $(( etpad * 2 )) 0 && let off+=$etpad

	val=0
	printf "\n"
	for i in ${!vlindices[@]}
	do
		printf "\t<dataline offset=\"%08X\" hex=\"" $off

		nextval=${vlindices[(( i+1 ))]=${#values[@]}}
		while test $val -lt $nextval
		do
			value=${values[$val]}

			# Make the special reset value into a proper flag.
			test $value = 'Reset' && let value=16#8000

			# Make a 2's complement for a negative value.
			test $value -lt 0 && let value=16#10000+$value

			if test $tag != 'kerx'
			then
				# Unset the least significant bit of each value.
				let value-=$value%2

				# Set the list-end flag for the last value in a list.
				test $(( ++val )) -eq $nextval && let value+=1
			fi

			printf "%04X " $value && let off+=$vlsize

			# Place an end-of-list marker for the extended table.
			test $tag = 'kerx' && test $(( ++val )) -eq $nextval &&
				printf "%04X" $(( 16#FFFF )) && let off+=$vlsize
		done

		printf "\"/> <!-- %s -->\n" ${vlnames[$i]}
	done

	test $vlpad -ne 0 &&
		printf "\t<dataline offset=\"%08X\" hex=\"%0*X\"/>\n" \
			$off $(( vlpad * 2 )) 0 && let off+=$vlpad

done

} <$2

printf "\n</genericSFNTTable>\n"
exit
