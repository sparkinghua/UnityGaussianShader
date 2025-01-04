// SPDX-License-Identifier: MIT
Shader "Gaussian Splatting/Render Splats"
{
	Properties
    {
        _EnvMap ("Environment Map", CUBE) = "black" {}
		_FGLUT ("Fragile LUT", 2D) = "black" {}
		_MaxMipLevel ("Max Mip Level", Range(0, 11)) = 9
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" }

        Pass
        {
            ZWrite Off
            Blend OneMinusDstAlpha One
            Cull Off
            
CGPROGRAM
#pragma vertex vert
#pragma fragment frag
#pragma require compute
#pragma use_dxc

#include "GaussianSplatting.hlsl"

samplerCUBE _EnvMap;
sampler2D _FGLUT;
float _MaxMipLevel;

float _MIN_ROUGHNESS = 0.08;
float _MAX_ROUGHNESS = 0.5;

StructuredBuffer<uint> _OrderBuffer;

struct v2f
{
    half4 col : COLOR0;
	half4 spec : COLOR1;
    float2 pos : TEXCOORD0;
	float3 normal : TEXCOORD1;
	float3 viewdir : TEXCOORD2;
    float4 vertex : SV_POSITION;
};

StructuredBuffer<SplatViewData> _SplatViewData;
ByteAddressBuffer _SplatSelectedBits;
uint _SplatBitsValid;

v2f vert (uint vtxID : SV_VertexID, uint instID : SV_InstanceID)
{
    v2f o = (v2f)0;
    instID = _OrderBuffer[instID];
	SplatViewData view = _SplatViewData[instID];
	float4 centerClipPos = view.pos;
	bool behindCam = centerClipPos.w <= 0;
	if (behindCam)
	{
		o.vertex = asfloat(0x7fc00000); // NaN discards the primitive
	}
	else
	{
		o.col.r = f16tof32(view.color.x >> 16);
		o.col.g = f16tof32(view.color.x);
		o.col.b = f16tof32(view.color.y >> 16);
		o.col.a = f16tof32(view.color.y);

		o.spec.r = f16tof32(view.spec.x >> 16);
		o.spec.g = f16tof32(view.spec.x);
		o.spec.b = f16tof32(view.spec.y >> 16);
		o.spec.a = f16tof32(view.spec.y);

		o.viewdir = view.viewdir;
		o.normal = view.normal;

		uint idx = vtxID;
		float2 quadPos = float2(idx&1, (idx>>1)&1) * 2.0 - 1.0;
		quadPos *= 2;

		o.pos = quadPos;

		float2 deltaScreenPos = (quadPos.x * view.axis1 + quadPos.y * view.axis2) * 2 / _ScreenParams.xy;
		o.vertex = centerClipPos;
		o.vertex.xy += deltaScreenPos * centerClipPos.w;

		// is this splat selected?
		if (_SplatBitsValid)
		{
			uint wordIdx = instID / 32;
			uint bitIdx = instID & 31;
			uint selVal = _SplatSelectedBits.Load(wordIdx * 4);
			if (selVal & (1 << bitIdx))
			{
				o.col.a = -1;				
			}
		}
	}
    return o;
}

half4 frag (v2f i) : SV_Target
{
	float power = -dot(i.pos, i.pos);
	half alpha = exp(power);
	if (i.col.a >= 0)
	{
		alpha = saturate(alpha * i.col.a);
	}
	else
	{
		// "selected" splat: magenta outline, increase opacity, magenta tint
		half3 selectedColor = half3(1,0,1);
		if (alpha > 7.0/255.0)
		{
			if (alpha < 10.0/255.0)
			{
				alpha = 1;
				i.col.rgb = selectedColor;
			}
			alpha = saturate(alpha + 0.3);
		}
		i.col.rgb = lerp(i.col.rgb, selectedColor, 0.5);
	}
	
    if (alpha < 1.0/255.0)
        discard;

	float3 normal = normalize(i.normal);
	float3 viewdir = normalize(i.viewdir);
	float3 lightdir = reflect(-viewdir, normal);
	float  ndotv = abs(dot(normal, viewdir));

	half3 ks = i.spec.rgb;
	half  kr = i.spec.a;

	half3 ambient = texCUBElod(_EnvMap, float4(normal, _MaxMipLevel)).rgb;
	half3 specColor = ambient * (1.0 - ks);

	half2 fglutUV = saturate(half2(ndotv, kr));
	half2 fgLookup = tex2D(_FGLUT, fglutUV).rg;

	float mipLevel = 0;
	if (kr < _MAX_ROUGHNESS)
		mipLevel = (clamp(kr, _MIN_ROUGHNESS ,_MAX_ROUGHNESS) - _MIN_ROUGHNESS) / (_MAX_ROUGHNESS - _MIN_ROUGHNESS) * (_MaxMipLevel - 1);
	else
		mipLevel = (clamp(kr, _MAX_ROUGHNESS, 1) - _MAX_ROUGHNESS) / (1 - _MAX_ROUGHNESS) * (_MaxMipLevel - 1);
	mipLevel = clamp(mipLevel, 0, _MaxMipLevel);
	half3 envColor = texCUBElod(_EnvMap, float4(lightdir, mipLevel)).rgb;
	specColor += envColor * (ks * fgLookup.r + fgLookup.g);

	half3 color = i.col.rgb + specColor;
	// color = i.col.rgb;

    half4 res = half4(color * alpha, alpha);
    return res;
}
ENDCG
        }
    }
}
