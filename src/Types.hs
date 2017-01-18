{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveAnyClass            #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}

module Types where

import           Control.Applicative
import           Data.Aeson
import           Data.Map            as M
import           Data.Text           as T
import           Data.Time
import           Hasql.Pool          as P
import           Options.Generic

data CmdLine = CmdLine { configFile :: FilePath
                       } deriving Generic
instance ParseRecord CmdLine

data Layer = Layer { _layerQuery        :: Text
                   , _layerLastModified :: UTCTime
                   } deriving (Show, Eq, Generic)

instance FromJSON Layer where
  parseJSON (Object o) =
       Layer <$> o .: "query" <*> o .: "last-modified"
  parseJSON _ = Control.Applicative.empty

data Config = Config { _configPgConnection       :: Text
                     , _configPgPoolSize         :: Maybe Int
                     , _configPgTimeout          :: Maybe NominalDiffTime
                     , _configMapnikInputPlugins :: Maybe FilePath
                     , _configPort               :: Maybe Int
                     , _configLayers             :: Map Text Layer
                     } deriving (Show, Generic)

instance FromJSON Config where
  parseJSON (Object o) =
       Config <$> o .: "db-connection" <*> o .:? "db-pool-size" <*> o .:? "db-timeout" <*>
          o .:? "mapnik-input-plugins" <*> o .:? "port" <*> o .: "layers"
  parseJSON _ = Control.Applicative.empty

-- TODO: make lenses!
data ServerState = ServerState { _pool        :: P.Pool
                               , _pluginDir   :: FilePath
                               , _startTime   :: String
                               , _stateLayers :: Map Text Layer
                               }

data TileFeature = TileFeature { _geometry   :: Value
                               , _properties :: Map Text Text
                               }