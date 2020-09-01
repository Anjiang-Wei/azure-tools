#!/bin/bash

if [[ $1 == "" ]]; then
    echo "arg1 - Path to CSV file with project,sha,test"
    exit
fi

repo=$(git rev-parse HEAD)
echo "script vers: $repo"
dir=$(pwd)
echo "script dir: $dir"
starttime=$(date)
echo "starttime: $starttime"

RESULTSDIR=~/output/
mkdir -p ${RESULTSDIR}

modulekey() {
    projroot=$1
    moduledir=$2

    # In case it is not a subdirectory, handle it so does not use the .
    relpath=$(realpath $(dirname ${moduledir}) --relative-to ${projroot})
    if [[ ${relpath} == '.' ]]; then
        basename ${projroot}
        return
    fi

    # Otherwise convert into expected format
    echo $(basename ${projroot})-$(realpath $(dirname ${moduledir}) --relative-to ${projroot} | sed 's;/;-;g')
}

cd ~/
projfile=$1
rounds=$2
line=$(head -n 1 $projfile)

echo "================Starting experiment for input: $line"
slug=$(echo ${line} | cut -d',' -f1 | rev | cut -d'/' -f1-2 | rev)
sha=$(echo ${line} | cut -d',' -f2)
fullTestName=$(echo ${line} | cut -d',' -f3)
module=$(echo ${line} | cut -d',' -f4)
seed=$(echo ${line} | cut -d',' -f5)

MVNOPTIONS="-Ddependency-check.skip=true -Dgpg.skip=true -DfailIfNoTests=false -Dskip.installnodenpm -Dskip.npm -Dskip.yarn -Dlicense.skip -Dcheckstyle.skip -Drat.skip -Denforcer.skip -Danimal.sniffer.skip -Dmaven.javadoc.skip -Dfindbugs.skip -Dwarbucks.skip -Dmodernizer.skip -Dimpsort.skip -Dmdep.analyze.skip -Dpgpverify.skip -Dxml.skip"

modifiedslug=$(echo ${slug} | sed 's;/;.;' | tr '[:upper:]' '[:lower:]')
short_sha=${sha:0:7}
modifiedslug_with_sha="${modifiedslug}-${short_sha}"

# echo "================Cloning the project"
bash $dir/clone-project.sh "$slug" "$sha"
cd ~/$slug

echo "================Setting up test name"
testarg=""
if [[ $fullTestName == "-" ]] || [[ "$fullTestName" == "" ]]; then
    echo "No test name given for isolation. Exiting immediately"
    date
    exit 1
else
    formatTest="$(echo $fullTestName | rev | cut -d. -f2 | rev)#$(echo $fullTestName | rev | cut -d. -f1 | rev )"
    class="$(echo $fullTestName | rev | cut -d. -f2 | rev)"
    echo "Test name is given. Running isolation on the specific test: $formatTest"
    echo "class: $class"
    testarg="-Dtest=$formatTest"
fi

classloc=$(find -name $class.java)
if [[ -z $classloc ]]; then
    echo "exit: 100 No test class at this commit."
    exit 100
fi
classcount=$(find -name $class.java | wc -l)
if [[ "$classcount" != "1" ]]; then
    classloc=$(find -name $class.java | head -n 1)
    echo "Multiple test class found. Unsure which one to use. Choosing: $classloc. Other ones are:"
    find -name $class.java
fi

if [[ -z $module ]]; then
    module=$classloc
    while [[ "$module" != "." && "$module" != "" ]]; do
	module=$(echo $module | rev | cut -d'/' -f2- | rev)
	echo "Checking for pom at: $module"
	if [[ -f $module/pom.xml ]]; then
	    break;
	fi
    done
else
    echo "Module passed in from csv."
fi
echo "Location of module: $module"

# echo "================Installing the project"
bash $dir/install-project.sh "$slug" "$MVNOPTIONS" "$USER" "$module" "$sha" "$dir"
ret=${PIPESTATUS[0]}
mv mvn-install.log ${RESULTSDIR}
if [[ $ret != 0 ]]; then
    # mvn install does not compile - return 0
    echo "Compilation failed. Actual: $ret"
    exit 1
fi

# echo "================Setting up maven-surefire"
if [[ "apache.hbase-801fc05" == "$modifiedslug_with_sha" ]] && [[ $module == "./hbase-procedure" || $module == "./hbase-server" ]]; then
    # These project/modules run no tests when both Nondex and our custom surefire is used. If only Nondex or our custom surefire is used then it runs fine.
    echo "Skipping setting up custom maven for $modifiedslug_with_sha in $module"
else
    bash $dir/setup-custom-maven.sh "${RESULTSDIR}" "$dir" "$fullTestName" "$modifiedslug_with_sha" "$module"
fi
cd ~/$slug

echo "================Modifying pom for nondex"
if [[ "$modifiedslug_with_sha" == "hexagonframework.spring-data-ebean-dd11b97" ]]; then
    rm -rf pom.xml
    cp $dir/poms/${modifiedslug_with_sha}=pom.xml pom.xml
fi
bash $dir/nondex-files/modify-project.sh .

echo "================Running NonDex"
if [[ "$seed" != "" ]]; then
    echo "Seed is provided: $seed"
    seedarg="-DnondexSeed=$seed -DnondexRerun"
fi

if [[ "$slug" == "dropwizard/dropwizard" ]]; then
    # dropwizard module complains about missing dependency if one uses -pl for some modules. e.g., ./dropwizard-logging
    mvn nondex:nondex -DnondexMode=ONE -DnondexRuns=$rounds -pl $module -am ${testarg} ${MVNOPTIONS} $ordering ${seedarg} |& tee mvn-test.log
elif [[ "$slug" == "fhoeben/hsac-fitnesse-fixtures" ]]; then
    mvn nondex:nondex -DnondexMode=ONE -DnondexRuns=$rounds -pl $module ${testarg} ${MVNOPTIONS} $ordering -DskipITs ${seedarg} |& tee mvn-test.log
else
    mvn nondex:nondex -DnondexMode=ONE -DnondexRuns=$rounds -pl $module ${testarg} ${MVNOPTIONS} $ordering ${seedarg} |& tee mvn-test.log
fi
cp mvn-test.log ${RESULTSDIR}
awk "/Test results can be found/{t=0} {if(t)print} /Across all seeds/{t=1}" mvn-test.log > ${RESULTSDIR}/nod-tests.txt

echo "================Setup to parse test list"
pip install BeautifulSoup4
pip install lxml

echo "================Parsing test list"
mkdir -p ${RESULTSDIR}/nondex
for d in $(find $(pwd) -name ".nondex"); do
    mdir="${RESULTSDIR}/nondex/$(modulekey $(pwd) ${d})"
    cp -r ${d} $mdir

    echo "" > rounds-test-results.csv
    for f in $(find $mdir -name "TEST*.xml"); do
	uid=$(echo $f | rev | cut -d'/' -f2 | rev)
	root=$(echo $f | rev | cut -d'/' -f2- | rev)
	seed=$(grep "nondexSeed=" $root/config | cut -d'=' -f2)
	if [[ "$seed" != "" ]]; then
	    python $dir/python-scripts/parse_surefire_report.py $f $uid,$seed $fullTestName >> rounds-test-results.csv
	fi
    done
    cat rounds-test-results.csv | sort -u | awk NF > $mdir/rounds-test-results.csv
done

endtime=$(date)
echo "endtime: $endtime"
