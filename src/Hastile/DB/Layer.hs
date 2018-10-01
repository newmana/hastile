{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeOperators         #-}

module Hastile.DB.Layer where

import qualified Control.Foldl                  as Foldl
import           Control.Lens                   ((^.))
import           Control.Monad.IO.Class
import           Control.Monad.Reader.Class
import qualified Data.Aeson                     as Aeson
import qualified Data.Aeson.Types               as AesonTypes
import qualified Data.ByteString                as ByteString
import qualified Data.ByteString.Lazy           as LazyByteString
import qualified Data.ByteString.Lazy           as ByteStringLazy
import qualified Data.Ewkb                      as Ewkb
import qualified Data.Geometry.MapnikVectorTile as MapnikVectorTile
import qualified Data.Geometry.Types.Config     as TypesConfig
import qualified Data.Geometry.Types.Geography  as TypesGeography
import qualified Data.Geospatial                as Geospatial
import qualified Data.HashMap.Strict            as HashMapStrict
import           Data.Monoid                    ((<>))
import qualified Data.Sequence                  as Sequence
import qualified Data.Text                      as Text
import qualified Data.Text.Encoding             as TextEncoding
import qualified Geography.VectorTile           as VectorTile
import qualified Geography.VectorTile.Internal  as VectorTileInternal
import qualified Hasql.CursorQuery              as HasqlCursorQuery
import qualified Hasql.CursorQuery.Transactions as HasqlCursorQueryTransactions
import qualified Hasql.Decoders                 as HasqlDecoders
import qualified Hasql.Pool                     as HasqlPool
import qualified Hasql.Transaction.Sessions     as HasqlTransactionSession

import qualified Hastile.Lib.Tile               as TileLib
import qualified Hastile.Types.App              as App
import qualified Hastile.Types.Layer            as Layer
import qualified Hastile.Types.Layer.Format     as LayerFormat
import qualified Hastile.Types.Tile             as Tile

findFeatures :: (MonadIO m, MonadReader App.ServerState m) => TypesConfig.Config -> Layer.Layer -> TypesGeography.ZoomLevel -> (TypesGeography.Pixels, TypesGeography.Pixels) -> m (Either HasqlPool.UsageError (Sequence.Seq (Geospatial.GeoFeature AesonTypes.Value)))
findFeatures config layer z xy = do
  buffer <- asks (^. App.ssBuffer)
  hpool <- asks App._ssPool
  let bbox = TileLib.getBbox buffer z xy
      query = getLayerQuery config layer
      action = HasqlCursorQueryTransactions.cursorQuery bbox query
      session = HasqlTransactionSession.transaction HasqlTransactionSession.ReadCommitted HasqlTransactionSession.Read action
  liftIO $ HasqlPool.use hpool session

getLayerQuery :: TypesConfig.Config -> Layer.Layer -> HasqlCursorQuery.CursorQuery (Tile.BBox Tile.Metres) (Sequence.Seq (Geospatial.GeoFeature AesonTypes.Value))
getLayerQuery config layer =
  case layerFormat of
    LayerFormat.GeoJSON ->
      layerQueryGeoJSON tableName
    LayerFormat.WkbProperties ->
      layerQueryWkbProperties config tableName
  where
    tableName = Layer.getLayerSetting layer Layer._layerTableName
    layerFormat = Layer.getLayerSetting layer Layer._layerFormat

layerQueryGeoJSON :: Text.Text -> HasqlCursorQuery.CursorQuery (Tile.BBox Tile.Metres) (Sequence.Seq (Geospatial.GeoFeature AesonTypes.Value))
layerQueryGeoJSON tableName =
  HasqlCursorQuery.cursorQuery sql Tile.bboxEncoder (HasqlCursorQuery.reducingDecoder geoJsonDecoder foldSeq) HasqlCursorQuery.batchSize_10000
  where
    sql = TextEncoding.encodeUtf8 $ "SELECT geojson FROM " <> tableName <> layerQueryWhereClause

foldSeq :: Foldl.Fold a (Sequence.Seq a)
foldSeq = Foldl.Fold step begin done
  where
    begin = Sequence.empty

    step x a = x <> Sequence.singleton a

    done = id

-- Fold (x -> a -> x) x (x -> b) -- Fold step initial extract
data StreamingLayer = StreamingLayer
  { slKeys     :: HashMapStrict.HashMap ByteStringLazy.ByteString Int
  , slVals     :: HashMapStrict.HashMap VectorTile.Val Int
  , slFeatures :: Sequence.Seq VectorTileInternal.Feature
  }
--  M.Map Text Int -> M.Map VT.Val Int

foldLayer :: Foldl.Fold a (Sequence.Seq a)
foldLayer = Foldl.Fold step begin done
  where
    begin = StreamingLayer HashMapStrict.empty HashMapStrict.empty Sequence.empty

    step _ _ = undefined

    done = undefined

layerQueryWkbProperties :: TypesConfig.Config -> Text.Text -> HasqlCursorQuery.CursorQuery (Tile.BBox Tile.Metres) (Sequence.Seq (Geospatial.GeoFeature AesonTypes.Value))
layerQueryWkbProperties config tableName =
  HasqlCursorQuery.cursorQuery sql Tile.bboxEncoder (HasqlCursorQuery.reducingDecoder (wkbPropertiesDecoder config) foldSeq) HasqlCursorQuery.batchSize_10000
  where
    sql = TextEncoding.encodeUtf8 $ "SELECT ST_AsBinary(wkb_geometry), properties FROM " <> tableName <> layerQueryWhereClause

geoJsonDecoder :: HasqlDecoders.Row (Geospatial.GeoFeature AesonTypes.Value)
geoJsonDecoder =
  HasqlDecoders.column $ HasqlDecoders.jsonBytes $ convertDecoder eitherDecode
  where
    eitherDecode = Aeson.eitherDecode :: LazyByteString.ByteString -> Either String (Geospatial.GeoFeature AesonTypes.Value)

wkbPropertiesDecoder :: TypesConfig.Config -> HasqlDecoders.Row (Geospatial.GeoFeature AesonTypes.Value)
wkbPropertiesDecoder config =
  (\geom props -> Geospatial.GeoFeature Nothing (MapnikVectorTile.convertClipSimplify config geom) props Nothing)
    <$> HasqlDecoders.column (HasqlDecoders.custom (\_ -> convertDecoder Ewkb.parseByteString))
    <*> HasqlDecoders.column HasqlDecoders.json

convertDecoder :: (LazyByteString.ByteString -> Either String b) -> ByteString.ByteString -> Either Text.Text b
convertDecoder decoder =
  either (Left . Text.pack) Right . decoder . LazyByteString.fromStrict

layerQueryWhereClause :: Text.Text
layerQueryWhereClause =
  " WHERE ST_Intersects(wkb_geometry, ST_Transform(ST_SetSRID(ST_MakeBox2D(ST_MakePoint($1, $2), ST_MakePoint($3, $4)), 3857), 4326));"
