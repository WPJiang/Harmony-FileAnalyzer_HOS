/**
 * 增强的地理编码器
 *
 * 支持多种反查方案，按优先级排序：
 * 1. 高德API（国内，速度快，推荐首选）
 * 2. Nominatim API（国际，在线）
 * 3. 离线 fallback（坐标范围匹配中国城市，兜底）
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

interface CityRange {
  name: string;
  lat_min: number;
  lat_max: number;
  lon_min: number;
  lon_max: number;
}

// 高德API响应结构
interface AmapAddressComponent {
  province?: string;
  city?: string;
  district?: string;
  township?: string;
  street?: string;
  streetNumber?: string;
}

interface AmapRegeocode {
  formatted_address?: string;
  addressComponent?: AmapAddressComponent;
}

interface AmapResponse {
  status?: string;
  info?: string;
  regeocode?: AmapRegeocode;
}

// Nominatim响应结构
interface NominatimAddress {
  tourism?: string;
  amenity?: string;
  shop?: string;
  building?: string;
  road?: string;
  suburb?: string;
  city_district?: string;
  city?: string;
  town?: string;
  county?: string;
  display_name?: string;
}

interface NominatimResponse {
  address?: NominatimAddress;
  display_name?: string;
}

export class EnhancedGeocoder {
  // 高德API Key（Web服务类型）
  private amapKey: string = '5a00094dea3e454ab6f561ad86cc0d06';

  // 中国主要城市坐标范围
  private cities: CityRange[] = [
    { name: '北京', lat_min: 39.4, lat_max: 41.1, lon_min: 115.4, lon_max: 117.5 },
    { name: '上海', lat_min: 30.9, lat_max: 31.8, lon_min: 120.8, lon_max: 122.2 },
    { name: '深圳', lat_min: 22.3, lat_max: 22.9, lon_min: 113.7, lon_max: 114.7 },
    { name: '广州', lat_min: 22.7, lat_max: 23.6, lon_min: 112.9, lon_max: 114.0 },
    { name: '杭州', lat_min: 29.9, lat_max: 30.6, lon_min: 119.5, lon_max: 120.6 },
    { name: '成都', lat_min: 30.2, lat_max: 31.3, lon_min: 103.3, lon_max: 104.9 },
    { name: '西安', lat_min: 33.9, lat_max: 34.6, lon_min: 107.5, lon_max: 109.5 },
    { name: '武汉', lat_min: 30.2, lat_max: 31.0, lon_min: 113.7, lon_max: 115.1 },
    { name: '南京', lat_min: 31.8, lat_max: 32.3, lon_min: 118.5, lon_max: 119.2 },
    { name: '重庆', lat_min: 29.0, lat_max: 30.3, lon_min: 105.9, lon_max: 108.1 },
    { name: '天津', lat_min: 38.8, lat_max: 40.3, lon_min: 116.7, lon_max: 118.0 },
    { name: '苏州', lat_min: 31.2, lat_max: 31.8, lon_min: 119.9, lon_max: 121.0 },
    { name: '青岛', lat_min: 35.5, lat_max: 37.1, lon_min: 119.6, lon_max: 121.0 },
    { name: '大连', lat_min: 38.7, lat_max: 40.3, lon_min: 121.0, lon_max: 122.5 },
    { name: '厦门', lat_min: 24.2, lat_max: 24.9, lon_min: 117.9, lon_max: 118.6 },
    { name: '长沙', lat_min: 27.8, lat_max: 28.5, lon_min: 112.7, lon_max: 113.3 },
    { name: '郑州', lat_min: 34.4, lat_max: 34.9, lon_min: 113.4, lon_max: 114.2 },
    { name: '昆明', lat_min: 24.5, lat_max: 25.5, lon_min: 102.5, lon_max: 103.5 },
    { name: '哈尔滨', lat_min: 44.9, lat_max: 46.4, lon_min: 125.9, lon_max: 127.8 },
  ];

  /**
   * 设置高德API Key
   */
  setAmapKey(key: string): void {
    this.amapKey = key;
  }

  /**
   * 反查GPS坐标
   * 优先级：高德API -> Nominatim -> 离线 fallback
   */
  async reverseGeocode(lat: number, lon: number): Promise<string> {
    console.info(`[EnhancedGeocoder] 开始反查坐标: lat=${lat}, lon=${lon}`);

    // 方案1: 高德API（国内首选）
    if (this.amapKey) {
      try {
        console.info(`[EnhancedGeocoder] 尝试高德API...`);
        const result = await this.amapSearch(lat, lon);
        if (result) {
          console.info(`[EnhancedGeocoder] 高德API成功: ${result}`);
          return result;
        }
      } catch (e) {
        console.error(`[EnhancedGeocoder] 高德API失败: ${e}`);
      }
    }

    // 方案2: Nominatim API（国际备选）
    try {
      console.info(`[EnhancedGeocoder] 尝试Nominatim API...`);
      const result = await this.nominatimSearch(lat, lon);
      if (result) {
        console.info(`[EnhancedGeocoder] Nominatim成功: ${result}`);
        return result;
      }
    } catch (e) {
      console.error(`[EnhancedGeocoder] Nominatim失败: ${e}`);
    }

    // 方案3: 离线 fallback（兜底）
    console.info(`[EnhancedGeocoder] 使用离线fallback...`);
    const result = this.offlineFallback(lat, lon);
    if (result) {
      console.info(`[EnhancedGeocoder] 离线fallback成功: ${result}`);
      return result;
    }

    console.warn(`[EnhancedGeocoder] 所有方案均失败`);
    return '';
  }

  /**
   * 同步版本（仅使用离线fallback）
   */
  reverseGeocodeSync(lat: number, lon: number): string {
    return this.offlineFallback(lat, lon);
  }

  /**
   * 高德API逆地理编码
   * URL: https://restapi.amap.com/v3/geocode/regeo?key=KEY&location=lon,lat
   */
  private async amapSearch(lat: number, lon: number): Promise<string> {
    const url = 'https://restapi.amap.com/v3/geocode/regeo';
    // 高德坐标格式：经度,纬度（注意顺序与Nominatim相反）
    const params = `key=${this.amapKey}&location=${lon},${lat}&extensions=base&output=JSON`;

    console.info(`[EnhancedGeocoder] 高德API请求: ${url}?${params}`);

    return new Promise<string>((resolve, reject) => {
      const httpRequest = http.createHttp();

      httpRequest.request(
        `${url}?${params}`,
        {
          method: http.RequestMethod.GET,
          connectTimeout: 5000,
          readTimeout: 5000
        },
        (err, response) => {
          if (err) {
            console.error(`[EnhancedGeocoder] 高德请求错误: ${err.message}, code: ${err.code}`);
            reject(new Error(`高德请求失败: ${err.message}`));
            return;
          }

          console.info(`[EnhancedGeocoder] 高德响应码: ${response.responseCode}`);

          try {
            let responseStr = '';
            if (typeof response.result === 'string') {
              responseStr = response.result as string;
            } else if (response.result instanceof ArrayBuffer) {
              const decoder = new util.TextDecoder('utf-8');
              responseStr = decoder.decodeToString(new Uint8Array(response.result as ArrayBuffer));
            } else if (response.result) {
              responseStr = JSON.stringify(response.result);
            }

            if (!responseStr || response.responseCode !== 200) {
              reject(new Error(`高德响应异常: code=${response.responseCode}`));
              return;
            }

            const data: AmapResponse = JSON.parse(responseStr) as AmapResponse;

            if (data.status !== '1') {
              console.error(`[EnhancedGeocoder] 高德API返回错误: ${data.info}`);
              reject(new Error(`高德API错误: ${data.info}`));
              return;
            }

            const regeocode = data.regeocode;
            if (!regeocode) {
              resolve('');
              return;
            }

            // 构建地址字符串
            const addressComponent = regeocode.addressComponent;
            if (addressComponent) {
              const parts: string[] = [];

              // 精确地址：省 + 市 + 区 + 街道
              if (addressComponent.province) {
                parts.push(addressComponent.province);
              }
              if (addressComponent.city && addressComponent.city !== addressComponent.province) {
                parts.push(addressComponent.city);
              }
              if (addressComponent.district) {
                parts.push(addressComponent.district);
              }
              if (addressComponent.township) {
                parts.push(addressComponent.township);
              }

              if (parts.length > 0) {
                // 返回前3-4个部分
                const result = parts.slice(0, 4).join('');
                console.info(`[EnhancedGeocoder] 高德地址解析: ${result}`);
                resolve(result);
                return;
              }
            }

            // fallback: 使用formatted_address
            if (regeocode.formatted_address) {
              resolve(regeocode.formatted_address);
              return;
            }

            resolve('');
          } catch (parseErr) {
            console.error(`[EnhancedGeocoder] 高德响应解析失败: ${parseErr}`);
            reject(new Error(`高德响应解析失败: ${parseErr}`));
          }
        }
      );
    });
  }

  /**
   * Nominatim API 搜索（国际）
   */
  private async nominatimSearch(lat: number, lon: number): Promise<string> {
    const url = 'https://nominatim.openstreetmap.org/reverse';
    const params = `lat=${lat}&lon=${lon}&format=json&zoom=10&addressdetails=1&accept-language=zh-CN`;

    console.info(`[EnhancedGeocoder] Nominatim请求: ${url}?${params}`);

    const headers: Record<string, string> = {
      'User-Agent': 'FileAnalyzer/1.0',
      'Accept': 'application/json'
    };

    return new Promise<string>((resolve, reject) => {
      const httpRequest = http.createHttp();

      httpRequest.request(
        `${url}?${params}`,
        {
          method: http.RequestMethod.GET,
          header: headers,
          connectTimeout: 5000,
          readTimeout: 8000
        },
        (err, response) => {
          if (err) {
            console.error(`[EnhancedGeocoder] Nominatim请求错误: ${err.message}, code: ${err.code}`);
            reject(new Error(`Nominatim请求失败: ${err.message}`));
            return;
          }

          console.info(`[EnhancedGeocoder] Nominatim响应码: ${response.responseCode}`);

          try {
            let responseStr = '';
            if (typeof response.result === 'string') {
              responseStr = response.result as string;
            } else if (response.result instanceof ArrayBuffer) {
              const decoder = new util.TextDecoder('utf-8');
              responseStr = decoder.decodeToString(new Uint8Array(response.result as ArrayBuffer));
            } else if (response.result) {
              responseStr = JSON.stringify(response.result);
            }

            if (!responseStr || response.responseCode !== 200) {
              reject(new Error(`Nominatim响应异常: code=${response.responseCode}`));
              return;
            }

            const data: NominatimResponse = JSON.parse(responseStr) as NominatimResponse;
            const address = data.address;

            if (!address) {
              resolve('');
              return;
            }

            const locationParts: string[] = [];

            if (address.tourism) locationParts.push(address.tourism);
            if (address.amenity) locationParts.push(address.amenity);
            if (address.road) locationParts.push(address.road);

            if (address.suburb) {
              locationParts.push(address.suburb);
            } else if (address.city_district) {
              locationParts.push(address.city_district);
            }

            if (address.city) {
              locationParts.push(address.city);
            } else if (address.town) {
              locationParts.push(address.town);
            } else if (address.county) {
              locationParts.push(address.county);
            }

            if (locationParts.length > 0) {
              resolve(locationParts.slice(0, 3).join(', '));
              return;
            }

            if (data.display_name) {
              resolve(data.display_name.split(',')[0].trim());
              return;
            }

            resolve('');
          } catch (parseErr) {
            reject(new Error(`响应解析失败: ${parseErr}`));
          }
        }
      );
    });
  }

  /**
   * 离线 fallback（坐标范围匹配）
   */
  private offlineFallback(lat: number, lon: number): string {
    for (const city of this.cities) {
      if (lat >= city.lat_min && lat <= city.lat_max &&
          lon >= city.lon_min && lon <= city.lon_max) {
        return city.name;
      }
    }

    // 中国范围fallback
    if (3.0 <= lat && lat <= 54.0 && 73.0 <= lon && lon <= 135.0) {
      return '中国';
    }

    return '';
  }
}

/**
 * 全局实例
 */
let enhancedGeocoder: EnhancedGeocoder | null = null;

export function getEnhancedGeocoder(): EnhancedGeocoder {
  if (enhancedGeocoder === null) {
    enhancedGeocoder = new EnhancedGeocoder();
  }
  return enhancedGeocoder;
}

export async function reverseGeocode(lat: number, lon: number): Promise<string> {
  const geocoder = getEnhancedGeocoder();
  return geocoder.reverseGeocode(lat, lon);
}

export function reverseGeocodeSync(lat: number, lon: number): string {
  const geocoder = getEnhancedGeocoder();
  return geocoder.reverseGeocodeSync(lat, lon);
}