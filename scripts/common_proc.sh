# Some common function to share

SERVER_LOG_NAME="server.log"

# This command would cause recompilation, 
# but due to -o and -q switch it:
# 1) It works offline (i.e, it doesn't print a bunch of annoying messages caused by Maven re-checking dependencies status)
# 3) Works in a quite mode, i.e., doesn't print other warnings and stuff.
#export MVN_RUN_CMD="mvn -q -o compile exec:java "
export MVN_RUN_CMD="mvn -o compile exec:java "

# The safest way to use bash is to rely on "set -euxo pipefail"
# However, it causes multiple issues, e.g.:
#   1) $k variables are unbounded when parameters are unspecified. If you set
#      -u it makes parsing arguments more difficult.
#   2) When we use grep for flow control "set -e" will cause scripts to fail when
#      the grep fails.
# Info: https://coderwall.com/p/fkfaqq/safer-bash-scripts-with-set-euxo-pipefail
function execAndCheck {
  cmd0="$1"
  desc="$2"
  cmd="$cmd0"' ; (echo ${PIPESTATUS[*]} | grep -E "^0(\s+0)*$")'
  echo "$cmd0"
  bash -c "$cmd"
  # The status of the command sequence is
  #   i) The status of the last command, i.e., that of a grepping.
  #   ii)  *OR* the failure status of the whole bash -c operation,
  #        if it fails for some reason. One common reason: syntax error.
  if [ "$?" != "0" ] ; then
      echo "********************************************************************************"
      if [ "$desc" != "" ] ; then
        echo "  Command $desc failed:"
      else
        echo "  Command failed:"
      fi
      echo "$cmd0"
      echo "  Expanded cmd that was actually run in a separate shell:"
      echo "$cmd"
      echo "********************************************************************************"
      exit 1
  fi
}


function check {
  f="$?"
  name=$1
  if [ "$f" != "0" ] ; then
    echo "**************************************"
    echo "* Failed: $name"
    echo "**************************************"
    exit 1
  fi
}

function checkVarNonEmpty {
  name="$1"
  val="${!name}"
  if [ "$val" = "" ] ; then
    echo "Variable $name is not set!"
    exit 1
  fi
}

function check_pipe {
  f="${PIPESTATUS[*]}"
  name=$1
  if [ "$f" != "0 0" ] ; then
    echo "******************************************"
    echo "* Failed (pipe): $name, exit statuses: $f "
    echo "******************************************"
    exit 1
  fi
}

function wait_children {
  pidLIST=($@)
  echo "Waiting for ${#pidLIST[*]} child processes"
  for pid in ${pidLIST[*]} ; do
    wait $pid
    stat=$?
    if [ "$stat" != "0" ] ; then
      echo "Process with pid=$pid *FAILED*, status=$stat!"
      nfail=$(($nfail+1))
    else
      echo "Process with pid=$pid finished successfully."
    fi
  done
}

function save_server_logs {
  me=`basename "$0"`
  mv $SERVER_LOG_NAME $SERVER_LOG_NAME.$me
}

function getOS {
  uname|awk '{print $1}'
}

function setJavaMem {
  F1="$1"
  F2="$2"
  NO_MAX="$3"
  OS=$(getOS)
  if [ "$OS" = "Linux" ] ; then
    MEM_SIZE_MX_KB=`free|grep Mem|awk '{print $2}'`
  elif [ "$OS" = "Darwin" ] ; then
    # Assuming Macbook pro
    MEM_SIZE_MX_KB=$((16384*1024))
  else
    echo "Unsupported OS: $OS" 1>&2
    exit 1
  fi
  MEM_SIZE_MIN_KB=$(($F1*$MEM_SIZE_MX_KB/$F2))
  MEM_SIZE_MAX_KB=$((7*$MEM_SIZE_MX_KB/8))
  if [ "$NO_MAX" = "1" ] ; then
    export MAVEN_OPTS="-Xms${MEM_SIZE_MIN_KB}k -server"
  else
    export MAVEN_OPTS="-Xms${MEM_SIZE_MIN_KB}k -Xmx${MEM_SIZE_MAX_KB}k -server"
  fi
  echo "MAVEN_OPTS=$MAVEN_OPTS"
}

function get_metric_value {
  fileName="$1"
  metrName="$2"
  fgrep "$metrName" "$fileName" | awk -F: '{print $2}' | sed 's/^\s*//'
}

function getNumCpuCores {
  OS=$(getOS)
  if [ "$OS" = "Linux" ] ; then
    NUM_CPU_CORES=`scripts/exper/get_cpu_cores.py`
    check "getting the number of CPU cores, do you have /proc/cpu/info?"
  elif [ "$OS" = "Darwin" ] ; then
    NUM_CPU_CORES=4
  else
    echo "Cannot guess the # of cores for OS: $OS" 1>&2
    exit 1
  fi
  echo $NUM_CPU_CORES
}

# This function:
# 1. Identifies guesses what is the format of data: new JSONL or old series-of-XML format
# 2. Finds all sub-directories containing indexable data and makes a string 
#    that represents a list of comma-separated sub-directories with data. This string
#    can be passed to indexing (and querying) apps.
# Attention: it "returns" an array by setting a variable retVal (ugly but works reliably)
function getIndexQueryDataInfo {
  topDir="$1"
  indexDirs=""
  oldFile="SolrAnswerFile.txt"
  oldQueryFile="SolrQuestionFile.txt"
  newFile="AnswerFields.jsonl"
  newQueryFile="QuestionFields.jsonl"
  dataFileName=""
  queryFileName=""
  currDir="$PWD"
  cd "$topDir"
  for subDir in * ; do
    echo "Checking data sub-directory: $subDir"
    if [ -d "$subDir" ] ; then
      hasData=0
      if [ -f "$subDir/$oldFile" ] ; then
        if [ -f "$subDir/$oldFile" ] ; then
          if [ "$dataFileName" = "$newFile" ] ; then
            echo "Inconsistent use of XML/JSONL formats"
            exit 1
          fi
          dataFileName=$oldFile
          qyeryFileName=$oldQueryFile
          hasData=1
        fi
      fi

      # New-layout/format data may be compressed, but queries shouldn't be compressed (and there's little sense to do so)
      for suff in "" ".gz" ".bz2" ; do
        fn=$subDir/${newFile}${suff}
        if [ -f "$fn" ] ; then
          echo "Found indexable data file: $fn"
          if [ "$dataFileName" = "$oldFile" ] ; then
            echo "Inconsistent use of XML/JSONL formats"
            exit 1
          fi
          dataFileName=${newFile}${suff}
          queryFileName=$newQueryFile
          hasData=1
          break
        fi
      done

      if [ "$hasData" = "1" ] ; then
        if [ "$indexDirs" != "" ] ; then
          indexDirs="$indexDirs,"
        fi
        indexDirs="${indexDirs}$subDir"
      fi
    fi # if [ -d "$subDir"]
  done
  queryDirs=""
  for subDir in * ; do
    if [ -d "$subDir" ] ; then
      fn=$subDir/${queryFileName}
      if [ -f "$fn" ] ; then
        echo "Found query file: $fn"
        if [ "queryDirs" != "" ] ; then
          queryDirs="$queryDirs,"
        fi
        queryDirs="${queryDirs}$subDir"
      fi
    fi
  done
  cd "$currDir"
  # This is kinda ugly, but is better than other non-portable solutions.
  retVal=("${indexDirs}" "${dataFileName}" "${queryDirs}" "${queryFileName}")
}

function getCatCmd {
  fileName=$1
  catCommand=""
  if [ -f "$fileName" ] ; then

    # Not all parts correspond to the data files
    echo "$fileName" | grep '^.gz$' >/dev/null
    if [ "$?" = "0" ] ; then
      catCommand="zcat"
    else
      echo "$fileName" | grep '^.bz2$' >/dev/null
      if [ "$?" = "0" ] ; then
        catCommand="zcat"
      else
        catCommand="cat"
      fi
    fi
  fi
  echo $catCommand
}
function getExperDirUnique {
  experDir="$1"
  testSet="$2"
  experSubdir="$3"

  checkVarNonEmpty "experDir"
  checkVarNonEmpty "testSet"
  checkVarNonEmpty "experSubdir"
 
  echo "$experDir/$testSet/$experSubdir"
  
}

function removeComment {
  line="$1"

  bash -c "echo \"$line\" | grep -E '^\s*[#]' >/dev/null"

  if [ "$?" = "0" ] ; then
    line=""
  fi


  echo $line
}
