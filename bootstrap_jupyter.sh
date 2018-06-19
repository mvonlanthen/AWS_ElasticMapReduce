#!/usr/bin/env bash

# Purpose
# -------
# Install anaconda and Jupyter notebook on EMR cluster. This script must be run 
# as a bootstrap at the cluster creation. Why? Because a bootstrap action runs 
# on every nodes, which is required to install Anaconda on all nodes.
#
# Don't forget to update the section "User Parameter"
#
# This script is based on this one:
# https://gist.github.com/nicor88/5260654eb26f6118772551861880dd67
#
# TO DO:
# - update to the latest miniconda

# Start
set -x -e

# - - - - - - - - - - - - - User Parameters - - - - - - - - - - - - - - - - - # 
JUPYTER_PASSWORD=${1:-"jupyterPassword"}
NOTEBOOK_DIR=${2:-"s3://spark-cluster-02a/notebooks/"}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

# home backup
if [ ! -d /mnt/home_backup ]; then
  sudo mkdir /mnt/home_backup
  sudo cp -a /home/* /mnt/home_backup
fi

# mount home to /mnt
if [ ! -d /mnt/home ]; then
  sudo mv /home/ /mnt/
  sudo ln -s /mnt/home /home
fi

# Install conda
# Miniconda is install because it's faster to install than Anaconda and smaller
# TO DO: update to the latest miniconda
wget https://repo.continuum.io/miniconda/Miniconda3-4.2.12-Linux-x86_64.sh -O /home/hadoop/miniconda.sh \
    && /bin/bash ~/miniconda.sh -b -p $HOME/conda

# update the bashrc
echo '' >> $HOME/.bashrc
echo '# export Ananconda binaries' >> $HOME/.bashrc
echo 'export PATH=$HOME/conda/bin:$PATH' >> $HOME/.bashrc && source $HOME/.bashrc

conda config --set always_yes yes --set changeps1 no

conda install -q conda

conda config -f --add channels conda-forge
conda config -f --add channels defaults

conda install -q hdfs3 findspark ujson jsonschema toolz boto3 py4j numpy pandas scipy

# cleanup
rm ~/miniconda.sh

echo bootstrap_conda.sh completed. PATH now: $PATH
export PYSPARK_PYTHON="/home/hadoop/conda/bin/python3.5"

# update the bashrc
# this is useful if you stop the jupyter notebook deamon and restart the 
# notebook without the deamon or run as python script with PySpark elements 
# in it. PySpark script can also be launch with the "PySpark" command.
# PS: I am note sure which line is absolutly necessary...
echo '' >> $HOME/.bashrc
echo '# Export PySpark. WARNING, your py4j version might change!' >> $HOME/.bashrc
echo 'export PYSPARK_PYTHON="/home/hadoop/conda/bin/python3.5"' >> $HOME/.bashrc
echo 'export SPARK_HOME=/usr/lib/spark' >> $HOME/.bashrc
echo 'export PYTHONPATH=$SPARK_HOME/python/lib/py4j-0.10.6-src.zip:$PYTHONPATH' >> $HOME/.bashrc
echo 'export PYTHONPATH=$SPARK_HOME/python:$PYTHONPATH' >> $HOME/.bashrc
source .bashrc


# - - - - - - - - - - - - - On the Master Node  - - - - - - - - - - - - - - - # 
IS_MASTER=false
if grep isMaster /mnt/var/lib/info/instance.json | grep true;
then
  IS_MASTER=true

  ### install dependencies for s3fs-fuse to access and store notebooks
  sudo yum install -y git
  sudo yum install -y libcurl libcurl-devel graphviz cyrus-sasl cyrus-sasl-devel readline readline-devel gnuplot
  sudo yum install -y automake fuse fuse-devel libxml2-devel

  # extract BUCKET and FOLDER to mount from NOTEBOOK_DIR
  NOTEBOOK_DIR="${NOTEBOOK_DIR%/}/"
  BUCKET=$(python -c "print('$NOTEBOOK_DIR'.split('//')[1].split('/')[0])")
  FOLDER=$(python -c "print('/'.join('$NOTEBOOK_DIR'.split('//')[1].split('/')[1:-1]))")

  echo "bucket '$BUCKET' folder '$FOLDER'"

  cd /mnt
  git clone https://github.com/s3fs-fuse/s3fs-fuse.git
  cd s3fs-fuse/
  ls -alrt
  ./autogen.sh
  ./configure
  make
  sudo make install
  sudo su -c 'echo user_allow_other >> /etc/fuse.conf'
  mkdir -p /mnt/s3fs-cache
  mkdir -p /mnt/$BUCKET
  /usr/local/bin/s3fs -o allow_other -o iam_role=auto -o umask=0 -o url=https://s3.amazonaws.com  -o no_check_certificate -o enable_noobj_cache -o use_cache=/mnt/s3fs-cache $BUCKET /mnt/$BUCKET

  ### Install Jupyter Notebook with conda and configure it.
  echo "installing python libs in master"
  # install
  conda install -q jupyter

  # install visualization libs
  conda install -q matplotlib plotly bokeh

  # install scikit-learn stable version
  conda install -q --channel scikit-learn-contrib scikit-learn

  # jupyter configs
  mkdir -p ~/.jupyter
  touch ls ~/.jupyter/jupyter_notebook_config.py
  HASHED_PASSWORD=$(python -c "from notebook.auth import passwd; print(passwd('$JUPYTER_PASSWORD'))")
  echo "c.NotebookApp.password = u'$HASHED_PASSWORD'" >> ~/.jupyter/jupyter_notebook_config.py
  echo "c.NotebookApp.open_browser = False" >> ~/.jupyter/jupyter_notebook_config.py
  echo "c.NotebookApp.ip = '*'" >> ~/.jupyter/jupyter_notebook_config.py
  echo "c.NotebookApp.notebook_dir = '/mnt/$BUCKET/$FOLDER'" >> ~/.jupyter/jupyter_notebook_config.py
  echo "c.ContentsManager.checkpoints_kwargs = {'root_dir': '.checkpoints'}" >> ~/.jupyter/jupyter_notebook_config.py

  ### Setup Jupyter deamon and launch it
  cd ~
  echo "Creating Jupyter Daemon"

  sudo cat <<EOF > /home/hadoop/jupyter.conf
description "Jupyter"
start on runlevel [2345]
stop on runlevel [016]
respawn
respawn limit 0 10
chdir /mnt/$BUCKET/$FOLDER
script
  sudo su - hadoop > /var/log/jupyter.log 2>&1 <<BASH_SCRIPT
        export PYSPARK_DRIVER_PYTHON="/home/hadoop/conda/bin/jupyter"
        export PYSPARK_DRIVER_PYTHON_OPTS="notebook --log-level=INFO"
        export PYSPARK_PYTHON=/home/hadoop/conda/bin/python3.5
        export JAVA_HOME="/etc/alternatives/jre"
        pyspark
  BASH_SCRIPT
end script
EOF

  sudo mv /home/hadoop/jupyter.conf /etc/init/
  sudo chown root:root /etc/init/jupyter.conf

  sudo initctl reload-configuration

  # start jupyter daemon
  echo "Starting Jupyter Daemon"
  sudo initctl start jupyter

fi