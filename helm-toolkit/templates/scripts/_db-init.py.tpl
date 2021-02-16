{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

{{- define "helm-toolkit.scripts.db_init" }}
#!/usr/bin/env python

# Creates db and user for an OpenStack Service:
# Set ROOT_DB_CONNECTION and DB_CONNECTION environment variables to contain
# SQLAlchemy strings for the root connection to the database and the one you
# wish the service to use. Alternatively, you can use an ini formatted config
# at the location specified by OPENSTACK_CONFIG_FILE, and extract the string
# from the key OPENSTACK_CONFIG_DB_KEY, in the section specified by
# OPENSTACK_CONFIG_DB_SECTION.

import os
import sys
try:
    import ConfigParser
    PARSER_OPTS = {}
    from urllib import urlencode
    from urlparse import urlunsplit
except ImportError:
    import configparser as ConfigParser
    PARSER_OPTS = {"strict": False}
    from urllib.parse import urlencode, urlunsplit
import logging
from sqlalchemy import create_engine
from sqlalchemy.sql import text

# Create logger, console handler and formatter
logger = logging.getLogger('OpenStack-Helm DB Init')
logger.setLevel(logging.DEBUG)
ch = logging.StreamHandler()
ch.setLevel(logging.DEBUG)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')

# Set the formatter and add the handler
ch.setFormatter(formatter)
logger.addHandler(ch)


# Get the connection string for the service db root user
if "ROOT_DB_CONNECTION" in os.environ:
    db_connection = os.environ['ROOT_DB_CONNECTION']
    logger.info('Got DB root connection')
else:
    logger.critical('environment variable ROOT_DB_CONNECTION not set')
    sys.exit(1)

mysql_x509 = os.getenv('MARIADB_X509', "")
ssl_args = {}
if mysql_x509:
    ssl_args = {'ssl': {'ca': '/etc/mysql/certs/ca.crt',
                'key': '/etc/mysql/certs/tls.key',
                'cert': '/etc/mysql/certs/tls.crt'}}

# Get the connection string for the service db
if "OPENSTACK_CONFIG_FILE" in os.environ:
    os_conf = os.environ['OPENSTACK_CONFIG_FILE']
    if "OPENSTACK_CONFIG_DB_SECTION" in os.environ:
        os_conf_section = os.environ['OPENSTACK_CONFIG_DB_SECTION']
    else:
        logger.critical('environment variable OPENSTACK_CONFIG_DB_SECTION not set')
        sys.exit(1)
    if "OPENSTACK_CONFIG_DB_KEY" in os.environ:
        os_conf_key = os.environ['OPENSTACK_CONFIG_DB_KEY']
    else:
        logger.critical('environment variable OPENSTACK_CONFIG_DB_KEY not set')
        sys.exit(1)
    try:
        config = ConfigParser.RawConfigParser(**PARSER_OPTS)
        logger.info("Using {0} as db config source".format(os_conf))
        config.read(os_conf)
        logger.info("Trying to load db config from {0}:{1}".format(
            os_conf_section, os_conf_key))
        user_db_conn = config.get(os_conf_section, os_conf_key)
        logger.info("Got config from {0}".format(os_conf))
    except:
        logger.critical("Tried to load config from {0} but failed.".format(os_conf))
        raise
elif "DB_CONNECTION" in os.environ:
    user_db_conn = os.environ['DB_CONNECTION']
    logger.info('Got config from DB_CONNECTION env var')
else:
    logger.critical('Could not get db config, either from config file or env var')
    sys.exit(1)

ENGINE_ROOT_DB = {
  "mysql": "/mysql",
  "postgresql": "/postgres"
}

# Root DB engine
try:
    root_engine_full = create_engine(db_connection)
    root_user = root_engine_full.url.username
    root_password = root_engine_full.url.password
    drivername = root_engine_full.url.drivername
    host = root_engine_full.url.host
    port = root_engine_full.url.port
    root_engine_url = urlunsplit([
        drivername,
        '{user}:{pwd}@{host}:{port}'.format(user=root_user, pwd=root_password, host=host, port=port),
        ENGINE_ROOT_DB.get(root_engine_full.engine.name, '/'),
        urlencode(root_engine_full.url.query),
        ''
    ])
    root_engine = create_engine(root_engine_url, connect_args=ssl_args, isolation_level='AUTOCOMMIT')
    connection = root_engine.connect()
    connection.close()
    logger.info("Tested connection to DB @ {0}:{1} as {2}".format(
        host, port, root_user))
except:
    logger.critical('Could not connect to database as root user')
    raise

# User DB engine
try:
    user_engine = create_engine(user_db_conn, connect_args=ssl_args, isolation_level='AUTOCOMMIT')
    # Get our user data out of the user_engine
    database = user_engine.url.database
    user = user_engine.url.username
    password = user_engine.url.password
    logger.info('Got user db config')
except:
    logger.critical('Could not get user database config')
    raise

if root_engine.engine.name == 'mysql':
    # Create DB
    try:
        root_engine.execute("CREATE DATABASE IF NOT EXISTS {0}".format(database))
        logger.info("Created database {0}".format(database))
    except:
        logger.critical("Could not create database {0}".format(database))
        raise

    # Create DB User
    try:
        root_engine.execute(
            "CREATE USER IF NOT EXISTS \'{user}\'@\'%%\' IDENTIFIED BY \'{pwd}\'".format(
                user=user, pwd=password))
        root_engine.execute(
            "GRANT ALL ON `{db}`.* TO \'{user}\'@\'%%\'".format(
                db=database, user=user))
        logger.info("Created user {0} for {1}".format(user, database))
    except:
        logger.critical("Could not create user {0} for {1}".format(user, database))
        raise
elif root_engine.engine.name == 'postgresql':
    if root_engine.engine.driver == 'psycopg2':
        import psycopg2.sql

    # Create DB User
    try:
        if not root_engine.execute(
            text("SELECT 1 FROM pg_catalog.pg_authid WHERE rolname = :role"),
            role=user
        ).fetchall():
            stmt = "CREATE ROLE :role INHERIT LOGIN ENCRYPTED PASSWORD :pwd"
            if root_engine.engine.driver == 'psycopg2':
                try:
                    db_conn = root_engine.raw_connection()
                    stmt = psycopg2.sql.SQL("CREATE ROLE {role} INHERIT LOGIN ENCRYPTED PASSWORD :pwd").format(
                        role=psycopg2.sql.Identifier(user)
                    ).as_string(db_conn.cursor())
                finally:
                    db_conn.close()
            root_engine.execute(text(stmt), role=user, pwd=password)
            logger.info("Created user {0}".format(user))
    except:
        logger.critical("Could not create user {0}".format(user))
        raise

    # Create DB
    try:
        if not root_engine.execute(
            text("SELECT 1 FROM pg_catalog.pg_database WHERE datname = :db"),
            db=database
        ).fetchall():
            stmt = "CREATE DATABASE :db OWNER :owner ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8'"
            if root_engine.engine.driver == 'psycopg2':
                try:
                    db_conn = root_engine.raw_connection()
                    stmt = psycopg2.sql.SQL("CREATE DATABASE {db} OWNER {owner} ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8'").format(
                        db=psycopg2.sql.Identifier(database),
                        owner=psycopg2.sql.Identifier(user)
                    ).as_string(db_conn.cursor())
                finally:
                    db_conn.close()
            root_engine.execute(text(stmt), db=database, owner=user)
            logger.info("Created database {0} with owner {1}".format(database, user))
    except:
        logger.critical("Could not create database {0} with owner {1}".format(database, user))
        raise

# Test connection
try:
    connection = user_engine.connect()
    connection.close()
    logger.info("Tested connection to DB @ {0}:{1}/{2} as {3}".format(
        host, port, database, user))
except:
    logger.critical('Could not connect to database as user')
    raise

logger.info('Finished DB Management')
{{- end }}
